"""The command line: `hq <command>` parsed, and only the module that runs it imported.

Each command names its function as "module.function": importing every module up front would cost
each `hq` run (the board runs several a refresh) the time to load all of them.
"""
import argparse
import importlib

from .core import SITE_SERVICES
from .projects import PROJECT_KINDS


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(prog="hq", description="task headquarters for Claude Code")
    sub = ap.add_subparsers(dest="cmd")

    p = sub.add_parser("board", help="print the board"); p.add_argument("--all", action="store_true")
    p.add_argument("--json", action="store_true"); p.set_defaults(fn="board.cmd_board")
    p = sub.add_parser("show", help="print a task card and its open asks"); p.add_argument("task")
    p.set_defaults(fn="board.cmd_show")
    p = sub.add_parser("new", help="create a task card: hq new TITLE [--project P] [--template T] [--goal G] [--phase PH]")
    p.add_argument("title", nargs="?", default=""); p.add_argument("--slug")
    p.add_argument("--category", help=argparse.SUPPRESS)   # retired: projects group tasks now
    p.add_argument("--project"); p.add_argument("--goal", help="what done looks like (the card's Goal section)")
    p.add_argument("--template", help="one of the project's templates (PROJECT.md \"Templates\"): title, goal, todos")
    p.add_argument("--phase", help="the phase of its project this task belongs to")
    p.add_argument("--no-focus", action="store_true", help="don't add it to Focus")
    p.add_argument("--lead"); p.add_argument("--workdir", action="append"); p.set_defaults(fn="commands.cmd_new")
    p = sub.add_parser("continue", help="continue an open task on a new card (its open todos, status and links "
                                        "carried over; the old card closed): hq continue T-072 [--title T]")
    p.add_argument("task"); p.add_argument("--title", help="the new card's title (default: the old one, re-dated)")
    p.add_argument("--json", action="store_true"); p.set_defaults(fn="continuation.cmd_continue")
    p = sub.add_parser("secretary", help="the secretary: hq secretary [init [--lang zh|en]] [--json]")
    p.add_argument("action", nargs="?", choices=["show", "init"], default="show")
    p.add_argument("--lang", default="en"); p.add_argument("--json", action="store_true")
    p.set_defaults(fn="reports.cmd_secretary")
    p = sub.add_parser("report", help="the secretary's reports: hq report [auto|daily|weekly] [--since T] [--json] "
                                      "| keep FILE | list [--json]")
    p.add_argument("action", nargs="?", choices=["auto", "daily", "weekly", "keep", "list"], default="auto")
    p.add_argument("name", nargs="?", help="keep: the report's file name")
    p.add_argument("--since", help="start of the window (date or local time) instead of the default")
    p.add_argument("--no-gh", action="store_true", help="don't look up PR states with gh")
    p.add_argument("--json", action="store_true"); p.set_defaults(fn="reports.cmd_report")
    p = sub.add_parser("inbox", help="quick notes: hq inbox [list] | add TEXT [--image P] [--sort] | sort N-1 | "
                                       "move N-1 task|todo|note|update|me|unsorted [--task T-1 …] "
                                       "[--next … --state … --status … --done TODO …] | drop N-1 | restore N-1")
    p.add_argument("action", nargs="?", choices=["list", "add", "sort", "move", "drop", "restore"], default="list")
    p.add_argument("rest", nargs="*"); p.add_argument("--image", action="append")
    p.add_argument("--via", default="cli"); p.add_argument("--sort", action="store_true")
    p.add_argument("--claude", help="the claude CLI to sort with (default: found on PATH)")
    for f in ("task", "owner", "text", "title", "project", "workdir", "next", "state", "status"):
        p.add_argument("--" + f)
    p.add_argument("--done", action="append", help="update: an open todo it ticks (repeat for more)")
    p.add_argument("--category", help=argparse.SUPPRESS)   # retired: accepted, ignored
    p.add_argument("--all", action="store_true"); p.add_argument("--json", action="store_true")
    p.set_defaults(fn="inbox.cmd_inbox")
    p = sub.add_parser("feed", help="messages from outside into the inbox: hq feed [status] | zulip | jira "
                                      "[--site URL] | all [--since HOURS] [--no-sort] [--dry-run] [--json]")
    p.add_argument("action", nargs="?", choices=["status", "zulip", "jira", "all"], default="status")
    p.add_argument("--site", help="hq feed jira: your Jira site (https://<you>.atlassian.net), remembered as hq site jira")
    p.add_argument("--since", type=float, help="how many hours the first scan looks back (default: from the start of today)")
    p.add_argument("--no-sort", action="store_true"); p.add_argument("--dry-run", action="store_true")
    p.add_argument("--claude", help="the claude CLI to sort with (default: found on PATH)")
    p.add_argument("--json", action="store_true"); p.set_defaults(fn="feeds.cmd_feed")
    p = sub.add_parser("intake", help="work that comes in by itself (a duty's Auto intake): hq intake [scan] "
                                        "[--dry-run] [--json] | status [--json]")
    p.add_argument("action", nargs="?", choices=["scan", "status"], default="scan")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--claude", help="the claude CLI to start sessions with (default: found on PATH)")
    p.add_argument("--json", action="store_true"); p.set_defaults(fn="intake.cmd_intake")
    p = sub.add_parser("autoclose", help="close todos whose PR merged, Jira issue is done or Jenkins build passed: "
                                           "hq autoclose [--dry-run] [--verbose] [--json]")
    p.add_argument("--dry-run", action="store_true"); p.add_argument("-v", "--verbose", action="store_true")
    p.add_argument("--json", action="store_true"); p.set_defaults(fn="autoclose.cmd_autoclose")
    p = sub.add_parser("site", help="this machine's Jira / Jenkins sites: hq site [jira|jenkins [URL | -]]")
    p.add_argument("service", nargs="?", choices=list(SITE_SERVICES)); p.add_argument("url", nargs="?")
    p.set_defaults(fn="feeds.cmd_site")
    p = sub.add_parser("bind", help="bind this Claude session to a task"); p.add_argument("task")
    p.add_argument("--session"); p.set_defaults(fn="commands.cmd_bind")
    p = sub.add_parser("unbind"); p.add_argument("--session"); p.set_defaults(fn="commands.cmd_unbind")
    p = sub.add_parser("whoami", help="task bound to this session"); p.add_argument("--session")
    p.set_defaults(fn="commands.cmd_whoami")
    p = sub.add_parser("touch", help="mark a card as reviewed today"); p.add_argument("task")
    p.set_defaults(fn="commands.cmd_touch")
    p = sub.add_parser("log", help="append a decision/progress line"); p.add_argument("task")
    p.add_argument("message"); p.set_defaults(fn="commands.cmd_log")
    p = sub.add_parser("set", help="set frontmatter fields: hq set T-1 status=done next=...")
    p.add_argument("task"); p.add_argument("fields", nargs="+"); p.set_defaults(fn="commands.cmd_set")
    p = sub.add_parser("todo", help="mark todo #n: hq todo T-1 2 done|drop|open")
    p.add_argument("task"); p.add_argument("index", type=int)
    p.add_argument("state", choices=["done", "drop", "open"]); p.add_argument("--via", default="cli")
    p.add_argument("--text", help="the todo's text as last seen; used if #n no longer matches")
    p.set_defaults(fn="commands.cmd_todo")
    # Retired (projects and duties group tasks now): kept for old cards and scripts, not advertised.
    p = sub.add_parser("category")
    p.add_argument("action", choices=["list", "add", "rename", "remove"]); p.add_argument("names", nargs="*")
    p.add_argument("--to"); p.add_argument("--json", action="store_true"); p.set_defaults(fn="commands.cmd_category")
    p = sub.add_parser("project", help="hq project list | show NAME | brief NAME | add NAME [--kind goal|duty] "
                                         "[--title T] [--due D] [--parent DUTY] [--path DIR] | set NAME key=value... | "
                                         "section NAME goal|out|done_when|templates|intake|brief [TEXT] | check NAME N [done|open] | "
                                         "paths NAME DIR... | rename OLD NEW | remove NAME [--to OTHER] | auto | order NAME...")
    p.add_argument("action", choices=["list", "show", "brief", "add", "set", "section", "check", "paths",
                                      "rename", "remove", "auto", "order"])
    p.add_argument("names", nargs="*"); p.add_argument("--path", action="append"); p.add_argument("--to")
    p.add_argument("--kind", choices=list(PROJECT_KINDS)); p.add_argument("--title"); p.add_argument("--due")
    p.add_argument("--parent", help="the duty a goal sits under")
    p.add_argument("--json", action="store_true"); p.set_defaults(fn="projects.cmd_project")
    p = sub.add_parser("focus", help="the Focus list: hq focus [add|remove|order T-012 ...] [--json]")
    p.add_argument("action", nargs="?", choices=["show", "add", "remove", "order", "carry"], default="show")
    p.add_argument("tasks", nargs="*"); p.add_argument("--json", action="store_true"); p.set_defaults(fn="commands.cmd_focus")
    p = sub.add_parser("ref", help="hq ref add|pin|remove T-1 <url or ticket> | restore T-1 <JSON from remove>")
    p.add_argument("action", choices=["add", "pin", "remove", "restore"]); p.add_argument("task"); p.add_argument("ref")
    p.set_defaults(fn="commands.cmd_ref")
    p = sub.add_parser("workdir", help="hq workdir add|remove T-1 PATH | restore T-1 <JSON from remove> — the task's folders (New session starts in the first)")
    p.add_argument("action", choices=["add", "remove", "restore"]); p.add_argument("task"); p.add_argument("path")
    p.set_defaults(fn="commands.cmd_workdir")
    p = sub.add_parser("addtodo", help="append a todo: hq addtodo T-1 '@me send the reply'")
    p.add_argument("task"); p.add_argument("text"); p.set_defaults(fn="commands.cmd_addtodo")
    p = sub.add_parser("ask", help="hq ask add <task> <text…> | resolve <ask-id> <res> [note…] | reopen <ask-id>")
    p.add_argument("action", choices=["add", "resolve", "reopen", "delivered", "snooze"]); p.add_argument("target")
    p.add_argument("rest", nargs="*"); p.add_argument("--via", default="cli"); p.add_argument("--note")
    p.add_argument("--session"); p.add_argument("--undo", action="store_true")
    p.add_argument("--until", help="snooze, resolve … later: hide the ask until this local time (default: tomorrow 00:00; \"\" clears)")
    p.set_defaults(fn="commands.cmd_ask")
    p = sub.add_parser("asks", help="list open asks"); p.add_argument("task", nargs="?")
    p.add_argument("--all", action="store_true"); p.add_argument("--json", action="store_true")
    p.set_defaults(fn="commands.cmd_asks")
    p = sub.add_parser("scan", help="recent sessions from existing transcripts, grouped by repository (onboarding)")
    p.add_argument("--days", type=int, default=60); p.add_argument("--json", action="store_true")
    p.add_argument("--apply-projects", action="store_true"); p.add_argument("--only")
    p.set_defaults(fn="onboard.cmd_scan")
    p = sub.add_parser("import", help="create the projects and task cards of an onboarding plan (JSON; /hq-onboard writes it)")
    p.add_argument("plan", help="the plan's file, or - for stdin")
    p.add_argument("--dry-run", action="store_true", help="check it and show what it would create; write nothing")
    p.add_argument("--json", action="store_true"); p.set_defaults(fn="onboard.cmd_import")
    p = sub.add_parser("sessions", help="live Claude Code sessions (needs Claude Pet)")
    p.add_argument("--json", action="store_true"); p.set_defaults(fn="peek.cmd_sessions")
    p = sub.add_parser("peek", help="recent messages of a live session"); p.add_argument("session")
    p.add_argument("-n", type=int, default=8); p.add_argument("--json", action="store_true")
    p.add_argument("--meta", action="store_true",
                   help="with --json: an object with title, cwd, live, tool calls, the turn, Claude's todos")
    p.add_argument("--tool", metavar="ID", help="one tool call's full input and output (id from --meta items)")
    p.add_argument("--commands", action="store_true",
                   help="the skills this session can run as slash commands, as Claude Code listed them")
    p.set_defaults(fn="peek.cmd_peek")
    p = sub.add_parser("jumps", help="how often you jumped to a terminal, by session state and where you clicked")
    p.add_argument("--days", type=int, default=7); p.add_argument("--json", action="store_true")
    p.set_defaults(fn="peek.cmd_jumps")
    p = sub.add_parser("history", help="sessions that worked on a task, newest first (to resume one)")
    p.add_argument("task"); p.add_argument("--json", action="store_true"); p.set_defaults(fn="peek.cmd_history")
    p = sub.add_parser("status", help="where tasks stand, with flags where card and sessions disagree "
                                        "(default: every open task)")
    p.add_argument("tasks", nargs="*"); p.add_argument("--focus", action="store_true", help="the Focus list's tasks")
    p.add_argument("--flagged", action="store_true", help="only tasks with a flag")
    p.add_argument("--json", action="store_true"); p.set_defaults(fn="status.cmd_status")
    p = sub.add_parser("garden", help="what a look over the board would tidy: zombie tasks, finished tasks with a "
                       "session still running, cards over budget, likely duplicates [--json]")
    p.add_argument("--json", action="store_true"); p.set_defaults(fn="garden.cmd_garden")
    p = sub.add_parser("hook", help="(internal) Claude Code hook entry point")
    p.set_defaults(fn="hooks.cmd_hook")

    args, extra = ap.parse_known_args()
    if extra:
        # Python < 3.12's argparse fills a nargs="*" positional with the first run of positionals
        # only, so `hq inbox add --sort TEXT` (or `add --json -- "-x"`) leaves TEXT over. For inbox
        # the leftovers are more of `rest`, in order; anything option-like before "--" is a typo.
        cut = extra.index("--") if "--" in extra else len(extra)
        bad = [x for x in extra[:cut] if x.startswith("-")]
        if getattr(args, "fn", None) != "inbox.cmd_inbox" or bad:
            ap.error("unrecognized arguments: " + " ".join(bad or extra))
        args.rest = list(args.rest or []) + extra[:cut] + extra[cut + 1:]
    if not getattr(args, "fn", None):
        ap.print_help()
        return
    module, name = args.fn.split(".")
    getattr(importlib.import_module("." + module, __package__), name)(args)
