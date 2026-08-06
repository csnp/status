"""Pull the shipped run: block, and the shipped env, out of deployment-drift.yml.

The point of extracting rather than re-typing is that what the cases drive is the same
text that runs on the runner. A harness with its own copy of the logic tests the copy.

That applies to the values as much as the logic. The first version of this file emitted
only the run: block and the cases supplied their own MAX_DATA_AGE_H=48, so raising the
shipped threshold to 999999 changed nothing the suite could see and the mutation survived.
A test that restates the implementation's constant is testing its own constant.
"""
import sys, yaml

wf = yaml.safe_load(open(sys.argv[1]))
job = wf["jobs"]["check"]
mode = sys.argv[2] if len(sys.argv) > 2 else "run"

if mode == "env":
    for k, v in (job.get("env") or {}).items():
        # Single-quoted: ISSUE_TITLE contains spaces, and an unquoted assignment silently
        # runs its second word as a command.
        sys.stdout.write("%s='%s'\n" % (k, str(v).replace("'", "'\\''")))
else:
    step = next(s for s in job["steps"] if s.get("id") == "check")
    sys.stdout.write(step["run"])
