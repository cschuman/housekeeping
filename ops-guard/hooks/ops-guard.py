#!/usr/bin/env python3
"""PreToolUse guard for Bash and Neon MCP calls: daemon locks, ask rules, read-only ssh.

Bash rules, first match wins (the lock check runs first and its deny beats all):
  1a  commands that touch a daemon take a per-daemon lock file; a lock held by
      another live session denies the call (stale after 600 s).
  1b  money-moving desk commands, prod DB writes and outbound email -> ask
      (email to only known recipients -> allow).
  1c  read-only ssh to the home fleet -> allow.
  1d  anything else -> no opinion.
Neon: read-only run_sql -> allow, write SQL and state-changing tools -> ask.

Decisions go to stdout as hookSpecificOutput JSON. No stdout + exit 0 means no
opinion. Unreadable payloads and internal errors fail open (no opinion). This
hook never returns updatedInput (rtk-rewrite.sh owns that) and never echoes
email subjects, bodies or secrets in a reason.
"""
import base64, binascii, email.parser, email.policy, email.utils, fcntl, json, os, re, shlex, sys, time

STALE_S = 600
MAX_CMD = 4096  # regex work only ever sees this many chars
MAX_PAYLOAD_FILE = 30 * 1024 * 1024
HOME = os.path.expanduser("~")


def lock_dir():
    return os.environ.get("OPS_LOCK_DIR") or os.path.join(HOME, ".claude", "locks")


def known_file():
    return os.environ.get("OPS_KNOWN_RECIPIENTS") or os.path.join(HOME, ".claude", "known-recipients.txt")


# ---------------------------------------------------------------- utilities

OP_CHARS = set("();<>|&")
SEP_OPS = {"&&", "||", ";", "|"}


def tokens(s):
    """Shell-ish tokens; unquoted operator runs come back as their own tokens."""
    lx = shlex.shlex(s, posix=True, punctuation_chars=True)
    lx.whitespace_split = True
    lx.commenters = ""
    return list(lx)


def is_op(tok):
    return bool(tok) and all(c in OP_CHARS for c in tok)


def has_subst(s):
    return any(x in s for x in ("\n", "\r", "`", "$(", "<(", ">("))


def segments(toks):
    """Split on && || ; |. Any other operator (redirect, &, parens) -> None."""
    segs, cur = [], []
    for t in toks:
        if is_op(t):
            if t not in SEP_OPS or not cur:
                return None
            segs.append(cur)
            cur = []
        else:
            cur.append(t)
    if not cur:
        return None
    segs.append(cur)
    return segs


SECRET_RES = [
    (re.compile(r"(?i)\b([A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PASSWD|PASS|KEY|DATABASE_URL|DSN|AUTH)[A-Z0-9_]*)=(\"[^\"]*\"|'[^']*'|\S+)"), r"\1=***"),
    (re.compile(r"(://)[^/\s:@]+:[^@\s/]+@"), r"\1***@"),
    (re.compile(r"(?i)(bearer\s+)\S+"), r"\1***"),
    (re.compile(r"(?i)(--?(?:password|token|secret|api-key|key)[= ])\S+"), r"\1***"),
    (re.compile(r"(?=[A-Za-z0-9_\-+/=]*\d)(?=[A-Za-z0-9_\-+/=]*[A-Za-z])[A-Za-z0-9_\-+/=]{32,}"), "***"),
]


def redact(s, n=120):
    s = re.sub(r"[\x00-\x1f\x7f]", " ", str(s))
    for rx, rep in SECRET_RES:
        s = rx.sub(rep, s)
    return s[:n]


def normalize(cmd):
    c = cmd.lstrip()
    for p in ("rtk proxy ", "rtk "):
        if c.startswith(p):
            return c[len(p):].lstrip()
    return c


# --------------------------------------------------- read-only command check

READ_VERBS = {"tail", "head", "cat", "ls", "stat", "wc", "grep", "rg", "find", "df", "du",
              "uptime", "free", "date", "pgrep", "ps", "crontab", "journalctl", "ss", "curl",
              "echo", "printf", "test", "[", "true", "id", "hostname", "which"}
SAFE_ENV = {"PATH", "TZ", "LANG", "LC_ALL", "TERM", "COLUMNS", "NO_COLOR"}
FIND_BAD = {"-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls"}
JOURNAL_BAD = ("--vacuum", "--rotate", "--flush", "--sync", "--relinquish-var",
               "--smart-relinquish-var", "--setup-keys", "--update-catalog")
HOSTNAME_OK = {"-f", "-s", "-i", "-I", "-d", "-a", "-A", "-y", "--fqdn", "--short",
               "--ip-address", "--all-ip-addresses", "--domain", "--alias", "--all-fqdns"}
CURL_SHORT_OK = set("sSfLIivk")
CURL_LONG_OK = {"--silent", "--show-error", "--fail", "--location", "--head", "--include",
                "--verbose", "--insecure", "--compressed", "--no-progress-meter"}
CURL_ARG_OK = {"-m", "--max-time", "--connect-timeout", "-w", "--write-out", "-H", "--header",
               "--retry", "-A", "--user-agent"}
SYSTEMCTL_OK = {"status", "list-timers", "list-units", "is-active", "show"}
GIT_OK = {"status", "log", "rev-parse", "diff", "show", "branch", "remote"}
GIT_BRANCH_BAD = {"-d", "-D", "-m", "-M", "-c", "-C", "-f", "--delete", "--move", "--copy",
                  "--force", "-u", "--set-upstream-to", "--unset-upstream", "--edit-description",
                  "--track", "--no-track"}
GIT_BRANCH_LIST = {"--list", "-l", "--contains", "--no-contains", "--merged", "--no-merged", "--points-at"}
TAILSCALE_OK = {"status", "ping", "ip"}


def _curl_ok(args):
    if any("@" in a for a in args):
        return False  # @file reads a local file into a header, form or write-out (exfil)
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("-o", "--output"):
            if i + 1 >= len(args) or args[i + 1] != "/dev/null":
                return False
            i += 2
            continue
        if a in CURL_ARG_OK:
            i += 2
            continue
        if a.startswith("--"):
            if a in CURL_LONG_OK or a.split("=", 1)[0] in CURL_ARG_OK:
                i += 1
                continue
            return False
        if a.startswith("-") and len(a) > 1:
            body = a[1:]
            # a short cluster may end in one arg-taking flag: -sSm5, -sw '%{..}'
            for k, ch in enumerate(body):
                if ch in CURL_SHORT_OK:
                    continue
                if "-" + ch in CURL_ARG_OK:
                    if k == len(body) - 1:
                        i += 1  # value is the next word
                    break
                if ch == "o" and k == len(body) - 1:
                    if i + 1 >= len(args) or args[i + 1] != "/dev/null":
                        return False
                    i += 1
                    break
                return False
            i += 1
            continue
        i += 1  # URL or value
    return True


def seg_read_only(w):
    i = 0
    while i < len(w):
        if w[i] == "env":
            i += 1
            continue
        m = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)=.*", w[i], re.S)
        if m:
            if m.group(1) not in SAFE_ENV and not m.group(1).startswith("LC_"):
                return False
            i += 1
            continue
        break
    if i >= len(w):
        return False
    verb, args = w[i], w[i + 1:]
    if verb == "cd":
        return True
    if verb == "python3":
        return len(args) >= 2 and args[0] == "-m" and args[1] in ("src.status", "src.hq")
    if verb == "systemctl":
        pos = [a for a in args if not a.startswith("-")]
        if any(a in ("-H", "--host", "-M", "--machine") or a.startswith(("--host=", "--machine=")) for a in args):
            return False
        return bool(pos) and pos[0] in SYSTEMCTL_OK
    if verb == "tailscale":
        pos = [a for a in args if not a.startswith("-")]
        return bool(pos) and pos[0] in TAILSCALE_OK
    if verb == "git":
        j = 0
        while j < len(args) and args[j].startswith("-"):
            if args[j] == "-C" and j + 1 < len(args):
                j += 2
            elif args[j] == "--no-pager":
                j += 1
            else:
                return False
        if j >= len(args) or args[j] not in GIT_OK:
            return False
        sub, rest = args[j], args[j + 1:]
        if any(a.startswith(("--output", "--ext-diff", "--textconv")) for a in rest):
            return False
        if sub == "branch":
            if any(a in GIT_BRANCH_BAD or a.startswith("--set-upstream") for a in rest):
                return False
            if any(not a.startswith("-") for a in rest) and not (set(rest) & GIT_BRANCH_LIST):
                return False
        if sub == "remote" and rest and rest[0] not in ("-v", "--verbose", "show", "get-url"):
            return False
        return True
    if verb not in READ_VERBS:
        return False
    if verb == "crontab":
        return args == ["-l"]
    if verb == "find":
        return not any(a in FIND_BAD for a in args)
    if verb == "rg":
        return not any(a == "--pre" or a.startswith("--pre=") for a in args)
    if verb == "journalctl":
        return not any(a.startswith(JOURNAL_BAD) for a in args)
    if verb == "ss":
        return not any(a == "--kill" or (re.fullmatch(r"-[A-Za-z]+", a) and "K" in a) for a in args)
    if verb == "date":
        for k, a in enumerate(args):
            if a in ("-s",) or a.startswith("--set"):
                return False
            if not a.startswith(("-", "+")) and not (k and args[k - 1] in ("-d", "--date", "-r", "--reference", "-f", "--file")):
                return False
        return True
    if verb == "hostname":
        return all(a in HOSTNAME_OK for a in args)
    if verb == "curl":
        return _curl_ok(args)
    return True


BRACE_EXP = re.compile(r"\{[^{}]*(,|\.\.)[^{}]*\}")


def read_only_string(s):
    """True when every segment of shell string s is a read-only command."""
    if not s.strip() or has_subst(s) or ">" in s:
        return False
    # The remote shell re-parses this string: any $ (${IFS}, $VAR, $'..'), any
    # backslash, and brace expansion ({-delete,x}) can rewrite argv after we check it.
    if "$" in s or "\\" in s or BRACE_EXP.search(s):
        return False
    try:
        toks = tokens(s)
    except ValueError:
        return False
    segs = segments(toks)
    return bool(segs) and all(seg_read_only(seg) for seg in segs)


# ------------------------------------------------------------------ ssh parse

SSH_HOST = re.compile(r"(casa|corey@casa(\.tailb77fc\.ts\.net)?|casa\.tailb77fc\.ts\.net|baby-bear-box|game-time)")
SSH_NOARG = set("qTntx46vC")
SSH_OPT_KEYS = {"connecttimeout", "batchmode", "serveraliveinterval", "serveralivecountmax",
                "loglevel", "connectionattempts"}


def _local_expansion(cmd):
    """True if the local shell would expand $, globs or escapes outside single quotes."""
    q = None
    for ch in cmd:
        if q == "'":
            if ch == "'":
                q = None
            continue
        if ch == "'" and q is None:
            q = "'"
        elif ch == '"':
            q = None if q == '"' else '"'
        elif ch in "$\\":
            return True
        elif q is None and ch in "*?[{":
            return True
    return False


def ssh_remote(cmd, need_host=True):
    """Remote command string of a plain `ssh [opts] host [opts] cmd...`, else None."""
    if has_subst(cmd) or _local_expansion(cmd):
        return None
    try:
        toks = tokens(cmd)
    except ValueError:
        return None
    if not toks or toks[0] != "ssh" or any(is_op(t) for t in toks):
        return None

    def opts(i):
        while i < len(toks) and toks[i].startswith("-"):
            t = toks[i]
            if t == "--":
                return i + 1, True
            body = t[1:]
            if not body:
                return None, False
            k = 0
            while k < len(body):
                ch = body[k]
                if ch in SSH_NOARG:
                    k += 1
                    continue
                if ch in "op":
                    val = body[k + 1:]
                    if not val:
                        i += 1
                        if i >= len(toks):
                            return None, False
                        val = toks[i]
                    if ch == "p" and not val.isdigit():
                        return None, False
                    if ch == "o":
                        key = re.split(r"[ =]", val, maxsplit=1)[0].lower()
                        if key not in SSH_OPT_KEYS:
                            return None, False
                    break
                return None, False
            i += 1
        return i, False

    i, term = opts(1)
    if i is None or i >= len(toks):
        return None
    host = toks[i]
    i += 1
    if not term:
        i, term = opts(i)
        if i is None:
            return None
    if need_host and not SSH_HOST.fullmatch(host):
        return None
    rest = toks[i:]
    return " ".join(rest) if rest else None


def is_read_only(cmd):
    if re.match(r"ssh\s", cmd):
        r = ssh_remote(cmd, need_host=False)
        return r is not None and read_only_string(r)
    return read_only_string(cmd)


# ---------------------------------------------------------------- 1a daemons

SITE_REPOS = ("nuggest", "family-wealth", "llm-spend", "claude-burn", "kalshi-desk",
              "crypto-desk", "netmap", "casablanca")
DIR_NOISE = {"scripts", "bin", "cron", "casa", "home", "corey", "Projects", "~", ".local", ""}


def _site_repo(cmd):
    for r in SITE_REPOS:
        if r in cmd:
            return r
    m = re.search(r"([^\s'\"]*)/(?:site_run|site-run|desk_site_keepalive)\.sh", cmd)
    if m:
        for part in reversed(m.group(1).split("/")):
            if part not in DIR_NOISE:
                return part
    return "site"


def _first_word_after(cmd, verb_end):
    rest = cmd[verb_end:]
    try:
        ws = tokens(rest)
    except ValueError:
        ws = rest.split()
    for w in ws:
        if is_op(w):
            break
        if not w.startswith("-"):
            return w
    return "unknown"


def _safe_key(k):
    k = re.sub(r"[^A-Za-z0-9._-]", "_", k).lstrip(".")
    return k[:80] or "unknown"


def daemon_key(cmd):
    if re.search(r"hot_loop|hot_cycle|kalshi-desk/(scripts|cron)/(activate_release|deploy|install_cron)", cmd) \
            or re.search(r"kalshi-desk.*(pkill|kill|restart)", cmd):
        return "casa-kalshi-hot-loop"
    if re.search(r"crypto-desk.*(bin/halt|bin/arm|install_cron|pkill|kill)", cmd):
        return "casa-crypto-desk"
    if re.search(r"netmap-run|netmap serve|(pkill|kill).*netmap", cmd):
        return "casa-netmap"
    if re.search(r"casablanca-run|(pkill|kill).*casablanca", cmd):
        return "casa-casablanca"
    m = re.search(r"(pkill|kill).*(nuggest|family-wealth|llm-spend|claude-burn)", cmd)
    if m:
        return "casa-" + m.group(2)
    if re.search(r"(site_run|site-run|desk_site_keepalive)\.sh", cmd):
        return _safe_key("casa-" + _site_repo(cmd))
    if re.search(r'(?i:com\.steno\.daemon)|steno-daemon|(pkill|killall).*steno|"cmd"\s*:\s*"(start|stop)"', cmd):
        return "local-steno"
    if re.search(r"\blaunchctl\s+(kickstart|bootout|bootstrap|unload|load|stop|start)\b", cmd):
        labels = re.findall(r"(?i)com\.[A-Za-z0-9._-]+", cmd)
        return _safe_key("local-launchd-" + (labels[-1].rstrip(".") if labels else "unknown"))
    m = re.search(r"\bsystemctl(\s+--user)?\s+(restart|stop|start|kill)\b", cmd) \
        or re.search(r"\b(pkill|killall)\b", cmd) \
        or re.search(r"\bkill\b(?=\s+[-%\w])", cmd)
    if m:
        return _safe_key("proc-" + _first_word_after(cmd, m.end()))
    return None


# ---------------------------------------------------------------- 1b ask rules

# Money and fly rules match a "view" of the command with quotes and backslashes
# removed (H"A"LT, H\ALT -> HALT) and, for fly, the app/config/token options removed.
DESK_ENTRY = r"(?:^|[;&|(]\s*|\b(?:sh|bash|exec|nohup|env|sudo)\s+)"
MONEY = [r"\btouch\b.*state/ARMED", r"\b(cp|mv|ln|install|tee)\b.*state/ARMED", r">\s*\S*state/ARMED",
         r"\brm\b.*state/HALT", r"\b(mv|unlink|shred)\b.*state/HALT", r"bin/arm",
         r"-m\s*src\.(execute|decide|run_trend|run_requote|run_wick|run_flush)\b",
         r"\bsrc/(execute|decide|run_trend|run_requote|run_wick|run_flush)\.py\b", r"\bhot_cycle\.sh\b"]
# Applied only when the command text names kalshi-desk or crypto-desk,
# so relative forms after `cd ~/kalshi-desk/state &&` are caught.
MONEY_DESK = [r"\btouch\b.*\bARMED\b", r"\b(cp|mv|ln|install|tee)\b.*\bARMED\b", r">\s*\S*ARMED\b",
              r"\brm\b.*\bHALT\b", r"\b(mv|unlink|shred)\b.*\bHALT\b",
              r"\./arm\b", DESK_ENTRY + r"arm(?![\w.-])",
              r"\bfind\b.*\s-(delete|exec|execdir|ok|okdir)\b",
              # a write verb plus anything the shell could expand into HALT/ARMED
              r"\b(rm|mv|unlink|shred|touch|cp|ln|install|tee)\b.*(\$|[*?\[]|\{[^{}]*(,|\.\.)[^{}]*\})"]
DESKS = re.compile(r"kalshi-desk|crypto-desk")
DB = [r"\bpnpm\s+(run\s+)?migrate", r"migrate:latest", r"\btsx\b.*migrate", r"DATABASE_URL_DIRECT=",
      r"MIGRATE_ALLOW_REMOTE",
      r"\bpnpm\s+(?:(?:-C|--dir|--filter|-F)(?:=|\s+)\S+\s+)+(?:run\s+)?(?:db:)?migrate\b",
      r"\bpnpm\s+(run\s+)?db:migrate\b", r"\bdrizzle-kit\s+(migrate|push)\b", r"\bnode\b.*migrate\.(m?js|ts)\b"]
FLY = [r"\b(fly|flyctl)\s+(postgres|pg)\s+connect\b",
       r"\b(fly|flyctl)\s+ssh\s+console\b",  # interactive or -C: a shell on a prod machine
       r"\b(fly|flyctl)\s+secrets\s+(set|unset|import|deploy)\b"]
# fly global options that may sit anywhere in argv: -a X, --app X, --app=X, -aX, -c/--config, -t/--access-token
FLY_OPTS = re.compile(r"(?<!\S)(?:(?:-a|-c|-t|--app|--config|--access-token)(?:=|\s+)\S+|-[act][^\s=-]\S*|"
                      r"--[a-z][a-z0-9-]*=\S+|--verbose|--debug)(?!\S)")  # any --flag=value too


def unquote_view(cmd):
    return re.sub(r"[\'\"\\]", "", cmd)


def fly_view(view):
    if not re.search(r"\bfly(ctl)?\b", view):
        return view
    return re.sub(r"\s+", " ", FLY_OPTS.sub(" ", view))
PSQL_READ = re.compile(r"(?is)^\s*(select|explain|show|\\d)")
SQL_WRITE_WORDS = re.compile(r"(?i)\b(insert|update|delete|merge|drop|alter|create|truncate|grant|revoke|copy|call|"
                             r"vacuum|reindex|cluster|refresh|lock|into|do|set_config|setval|nextval|dblink\w*|"
                             r"query_to_xml\w*|lo_\w+|pg_terminate_backend|pg_cancel_backend|pg_reload_conf|"
                             r"pg_create_\w+|pg_drop_\w+|pg_switch_wal|pg_promote)\b")


def _psql_argvs(s, depth=0):
    """argv lists for every psql invocation in s (searching nested quoted strings). None = unparsable."""
    try:
        toks = tokens(s)
    except ValueError:
        return None
    out = []
    for i, t in enumerate(toks):
        if os.path.basename(t) == "psql":
            argv = []
            for u in toks[i + 1:]:
                if is_op(u):
                    if u.startswith("<"):
                        argv.append("<")  # stdin redirect: payload unknown
                    break
                argv.append(u)
            out.append(argv)
        elif "psql" in t and depth < 3 and t != s:
            sub = _psql_argvs(t, depth + 1)
            if sub is None:
                return None
            out.extend(sub)
    return out


def psql_rule(cmd):
    if not re.search(r"\bpsql\b", cmd) or not re.search(r"neon\.tech|\$\{?DATABASE_URL", cmd):
        return None
    argvs = _psql_argvs(cmd)
    if not argvs:
        return ("ask", "psql against a prod database with unparsable arguments")
    for argv in argvs:
        payloads, k = [], 0
        while k < len(argv):
            a = argv[k]
            if a in ("-f", "--file", "<") or a.startswith("--file=") or (a.startswith("-f") and len(a) > 2 and not a.startswith("--")):
                return ("ask", "psql against a prod database runs a SQL file or stdin")
            if a == "--command":
                if k + 1 >= len(argv):
                    return ("ask", "psql -c without a payload")
                payloads.append(argv[k + 1])
                k += 2
                continue
            if a.startswith("--command="):
                payloads.append(a.split("=", 1)[1])
            elif re.fullmatch(r"-[A-Za-z0-9?]+", a):
                # short cluster such as -Atc: value-taking flags end the scan
                for pos, ch in enumerate(a[1:], 1):
                    if ch in "dhpUvPoLTFR":
                        break
                    if ch == "f":
                        return ("ask", "psql against a prod database runs a SQL file or stdin")
                    if ch == "c":
                        if a[pos + 1:]:
                            payloads.append(a[pos + 1:])
                        elif k + 1 < len(argv):
                            payloads.append(argv[k + 1])
                            k += 1
                        else:
                            return ("ask", "psql -c without a payload")
                        break
            k += 1
        if not payloads:
            return ("ask", "interactive psql against a prod database")
        for p in payloads:
            stmts = [x for x in p.split(";") if x.strip()]
            if not stmts:
                return ("ask", "psql -c with an empty payload")
            for st in stmts:
                if not PSQL_READ.match(st) or SQL_WRITE_WORDS.search(st) or st.strip().count("\\") > 1:
                    return ("ask", "psql write against a prod database")
    return None


def _known():
    try:
        with open(known_file(), encoding="utf-8") as fh:
            return {ln.strip().lower() for ln in fh if ln.strip() and not ln.strip().startswith("#")}
    except OSError:
        return set()


def _clean_addr(a):
    return re.sub(r"[^\w.@+\-]", "", a)[:80]


def _recipient_decision(addrs, compound, extra_ask=None):
    if not addrs:
        return ("ask", "could not determine recipients")
    known = _known()
    unknown = sorted({a for a in addrs if a not in known})
    if unknown:
        shown = ", ".join(_clean_addr(a) for a in unknown[:5])
        more = f" and {len(unknown) - 5} more" if len(unknown) > 5 else ""
        return ("ask", f"email to unknown recipient(s): {shown}{more}")
    n = len(set(addrs))
    if extra_ask:
        return ("ask", f"email to {n} known recipient(s) {extra_ask}")
    if compound:
        return ("ask", f"email to {n} known recipient(s) inside a compound command")
    return ("allow", f"email to {n} known recipient(s)")


def _read_payload_file(path, cwd):
    path = path.strip().strip("'\"")
    path = os.path.expanduser(path)
    if not os.path.isabs(path):
        path = os.path.join(cwd, path)
    if os.path.getsize(path) > MAX_PAYLOAD_FILE:
        raise ValueError("payload file too large")
    with open(path, encoding="utf-8") as fh:
        return fh.read()


ADDR_SCAN = re.compile(r"[^\s<>,;:\"()\[\]]+@[^\s<>,;:\"()\[\]]+")


def _raw_recipients(js):
    d = json.loads(js)
    if not isinstance(d, dict):
        raise ValueError("payload not an object")
    raw = d.get("raw")
    if not isinstance(raw, str):
        msg = d.get("message")
        raw = msg.get("raw") if isinstance(msg, dict) else None
    if not isinstance(raw, str) or not raw:
        raise ValueError("no raw message")
    data = base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4))
    msg = email.parser.BytesParser(policy=email.policy.compat32).parsebytes(data, headersonly=True)
    values = []
    for h in ("To", "Cc", "Bcc"):
        values += [str(v) for v in (msg.get_all(h) or [])]
    addrs = {a.strip().lower() for _, a in email.utils.getaddresses(values) if a.strip()}
    # Parser-differential guard: anything address-shaped in the raw header text counts too.
    for v in values:
        addrs |= {a.lower().strip(".") for a in ADDR_SCAN.findall(v)}
    return addrs


def _subseq(pos, pattern):
    k = 0
    for p in pos:
        if k < len(pattern) and p in pattern[k]:
            k += 1
    return k == len(pattern)


def email_rule(cmd, cwd):
    if not re.search(r"\bgws\b", cmd) or "gmail" not in cmd:
        return None
    cat = re.search(r"--json(?:=|\s+)\"?\$\(\s*cat\s+(['\"]?)([^'\"\s)]+)\1\s*\)\"?", cmd)
    probe = cmd[:cat.start()] + "--json X" + cmd[cat.end():] if cat else cmd
    try:
        toks = tokens(probe)
    except ValueError:
        if re.search(r"\bgws\b.*\bgmail\b.*(\bsend\b|\+send|\+reply|\+forward)", cmd):
            return ("ask", "could not determine recipients")
        return None
    compound = has_subst(probe) or any(is_op(t) for t in toks)
    for i, t in enumerate(toks):
        if os.path.basename(t) != "gws":
            continue
        seg = []
        for u in toks[i + 1:]:
            if is_op(u):
                break
            seg.append(u)
        pos = [u for u in seg if not u.startswith("-")]
        if "gmail" not in pos:
            continue
        after = pos[pos.index("gmail") + 1:]
        dry = "--dry-run" in seg or "--draft" in seg
        helper = next((p for p in after if p.startswith("+")), None)
        if helper in ("+reply", "+reply-all"):
            return None if dry else ("ask", "reply recipients come from the thread; could not determine recipients")
        if helper == "+forward":
            return None if dry else ("ask", "forwarding a message; confirm recipients")
        if helper == "+send":
            if dry:
                return None
            vals = []
            for k, u in enumerate(seg):
                for f in ("--to", "--cc", "--bcc"):
                    if u == f and k + 1 < len(seg):
                        vals.append(seg[k + 1])
                    elif u.startswith(f + "="):
                        vals.append(u.split("=", 1)[1])
            addrs = {a.strip().lower() for _, a in email.utils.getaddresses(vals) if a.strip()}
            for v in vals:
                addrs |= {a.lower() for a in ADDR_SCAN.findall(v)}
            attach = any(u in ("-a", "--attach") or u.startswith("--attach=") for u in seg)
            return _recipient_decision(addrs, compound, "with attachment(s)" if attach else None)
        if not _subseq(after, [("users",), ("messages", "drafts"), ("send",)]):
            continue
        if dry:
            return None
        try:
            if cat:
                js = _read_payload_file(cat.group(2), cwd)
            else:
                js = None
                for k, u in enumerate(seg):
                    if u == "--json" and k + 1 < len(seg):
                        js = seg[k + 1]
                    elif u.startswith("--json="):
                        js = u[len("--json="):]
                    if js is not None:
                        break
                if js is None:
                    raise ValueError("no --json payload")
                if js.startswith("@"):
                    js = _read_payload_file(js[1:], cwd)
            addrs = _raw_recipients(js)
        except (ValueError, OSError, TypeError, binascii.Error, UnicodeDecodeError, json.JSONDecodeError):
            return ("ask", "could not determine recipients")
        return _recipient_decision(addrs, compound)
    return None


def ask_rules(cmd, cwd):
    view = unquote_view(cmd)
    money = MONEY + (MONEY_DESK if DESKS.search(view) else [])
    for rx in money:
        if re.search(rx, view):
            return ("ask", "money-moving desk command (ARMED/HALT/arm/execute path)")
    for rx in DB:
        if re.search(rx, cmd) or re.search(rx, view):
            return ("ask", "prod database migration or direct-URL write")
    fv = fly_view(view)
    for rx in FLY:
        if re.search(rx, fv):
            return ("ask", "Fly secrets write, prod Postgres connect or ssh console")
    r = psql_rule(cmd)
    if r:
        return r
    return email_rule(cmd, cwd)


def ssh_allow(cmd):
    if not cmd.startswith("ssh "):
        return None
    r = ssh_remote(cmd, need_host=True)
    if r is not None and read_only_string(r):
        return ("allow", "read-only ssh to home fleet")
    return None


# ---------------------------------------------------------------- lock files

def _read_lock(path):
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def _lock_age(path, d):
    ts = d.get("ts")
    if not isinstance(ts, (int, float)):
        try:
            ts = os.path.getmtime(path)
        except OSError:
            ts = 0
    return int(time.time() - ts)


def _write_lock(path, sid, tuid, cmd):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as fh:
        json.dump({"session_id": sid, "tool_use_id": tuid, "cmd": redact(cmd, 120),
                   "ts": int(time.time())}, fh)


def _display(path):
    return "~" + path[len(HOME):] if path.startswith(HOME + os.sep) else path


def lock_and_decide(key, payload, cmd, decision):
    """Apply the daemon lock around an already-computed decision."""
    sid = str(payload.get("session_id") or "")
    tuid = str(payload.get("tool_use_id") or "")
    d = lock_dir()
    try:
        os.makedirs(d, mode=0o700, exist_ok=True)
        mfh = open(os.path.join(d, ".ops-guard.mutex"), "a+")
    except OSError as e:
        print(f"ops-guard: lock dir unavailable ({e}); not locking", file=sys.stderr)
        return decision
    path = os.path.join(d, key + ".lock")
    with mfh:
        fcntl.flock(mfh, fcntl.LOCK_EX)
        if os.path.lexists(path):
            held = _read_lock(path)
            age = _lock_age(path, held)
            hsid = str(held.get("session_id") or "")
            if 0 <= age <= STALE_S and not (sid and hsid == sid):  # future ts = stale
                return ("deny", f"{key} is held by session {redact(hsid, 8) or 'unknown'} for {age}s "
                                f"(cmd: {redact(held.get('cmd', ''), 60)}). Wait or rm {_display(path)}")
            if decision and decision[0] == "ask":
                return decision  # ask path never takes or refreshes a lock
            if not sid:
                return decision
            try:
                os.unlink(path)  # stale, or ours (re-entrant): refresh with this tool_use_id
            except OSError:
                pass
        elif decision and decision[0] == "ask":
            return decision
        if not sid:
            print("ops-guard: no session_id; not taking a lock", file=sys.stderr)
            return decision
        try:
            _write_lock(path, sid, tuid, cmd)
        except FileExistsError:
            return ("deny", f"{key} lock appeared concurrently. Retry or rm {_display(path)}")
        except OSError as e:
            print(f"ops-guard: could not write lock ({e})", file=sys.stderr)
    return decision


# ---------------------------------------------------------------- Neon rules

NEON_ASK = re.compile(r"^mcp__Neon__(delete_|reset_|rotate_|restore_|revoke_|suspend_|start_|set_default|"
                      r"complete_database_migration|prepare_database_migration|create_|update_|provision_|"
                      r"deploy_|register_|finalize_|recover_|disable_|complete_query_tuning|restart_postgres_endpoint|"
                      r"set_snapshot_schedule)")
NEON_READ = {"select", "with", "explain", "show", "values"}


def sql_split(sql):
    """Statements with comments removed and string/identifier contents blanked."""
    out, cur, i, n = [], [], 0, len(sql)
    while i < n:
        c = sql[i]
        if sql.startswith("--", i):
            j = sql.find("\n", i)
            i = n if j < 0 else j
            continue
        if sql.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if sql.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif sql.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
            cur.append(" ")
            continue
        if c in "'\"":
            j = i + 1
            while j < n:
                if sql[j] == c:
                    if j + 1 < n and sql[j + 1] == c:
                        j += 2
                        continue
                    break
                j += 1
            cur.append(c + c)
            i = j + 1
            continue
        m = re.match(r"\$([A-Za-z_][A-Za-z0-9_]*)?\$", sql[i:]) if c == "$" else None
        if m:
            tag = m.group(0)
            j = sql.find(tag, i + len(tag))
            cur.append("''")
            i = n if j < 0 else j + len(tag)
            continue
        if c == ";":
            out.append("".join(cur))
            cur = []
        else:
            cur.append(c)
        i += 1
    out.append("".join(cur))
    return [s for s in (x.strip() for x in out) if s]


def neon_rule(tool, ti):
    if tool in ("mcp__Neon__run_sql", "mcp__Neon__run_sql_transaction"):
        sql, stl = ti.get("sql"), ti.get("sqlStatements")
        if (sql is not None and not isinstance(sql, str)) or (stl is not None and (
                not isinstance(stl, list) or not all(isinstance(x, str) for x in stl))):
            return ("ask", "Neon SQL payload has non-text statements")
        texts = ([sql] if sql else []) + list(stl or [])
        stmts = [s for t in texts for s in sql_split(t)]
        if not stmts:
            return ("ask", "Neon SQL call with no readable statement")
        for st in stmts:
            m = re.match(r"\(*\s*([A-Za-z_]+)", st)
            verb = m.group(1).lower() if m else "?"
            if verb not in NEON_READ:
                return ("ask", f"Neon SQL statement starts with {verb.upper()}")
            w = SQL_WRITE_WORDS.search(st)
            if w:
                return ("ask", f"Neon SQL {verb.upper()} statement contains {w.group(1).upper()}")
        return ("allow", f"read-only Neon SQL ({len(stmts)} statement(s))")
    if NEON_ASK.match(tool):
        return ("ask", f"Neon {tool[len('mcp__Neon__'):]} changes project state")
    return None


# ---------------------------------------------------------------- main

# Literal-only scan of the part of an oversized command that the rules never see.
TAIL_TRIGGERS = re.compile(r"HALT|ARMED|\barm\b|hot_cycle|hot_loop|src[./]|migrate|\bfly|psql|gws|DATABASE_URL|"
                           r"kill|launchctl|systemctl|site_run|site-run|keepalive|netmap|casablanca|steno|ssh|drizzle|"
                           r"[*?\[].{0,20}(state/|-desk)|(state/|-desk).{0,20}[*?\[]")  # globs near desk paths


def bash_rules(payload, ti):
    raw = ti.get("command")
    if not isinstance(raw, str) or not raw.strip():
        return None
    over = len(raw) > MAX_CMD
    cmd = normalize(raw[:MAX_CMD])  # bound all regex/tokenizer work
    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else os.getcwd()
    decision = ask_rules(cmd, cwd) or ssh_allow(cmd)
    if over and (decision is None and TAIL_TRIGGERS.search(unquote_view(raw[MAX_CMD - 64:])) or decision and decision[0] == "allow"):
        # Never allow on a truncated view, and do not stay silent when the unseen tail mentions ops.
        decision = ("ask", f"command is {len(raw)} chars; only the first {MAX_CMD} were inspected")
    key = None if is_read_only(cmd) else daemon_key(cmd)
    if key:
        decision = lock_and_decide(key, payload, cmd, decision)
    return decision


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception as e:
        print(f"ops-guard: unreadable payload: {e}", file=sys.stderr)
        return
    if not isinstance(payload, dict):
        return
    tool = str(payload.get("tool_name") or "")
    ti = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    if tool == "Bash":
        res = bash_rules(payload, ti)
    elif tool.startswith("mcp__Neon__"):
        res = neon_rule(tool, ti)
    else:
        res = None
    if res:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                                 "permissionDecision": res[0],
                                                 "permissionDecisionReason": res[1]}}))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # fail open: never block on a bug in this hook
        print(f"ops-guard: internal error, no opinion: {type(e).__name__}", file=sys.stderr)
    sys.exit(0)
