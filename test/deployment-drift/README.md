# Tests for the deployment drift check

`.github/workflows/deployment-drift.yml` asks whether status.csnp.org is still telling the
truth. This directory is what stops that check quietly becoming decoration.

## Why it is here at all

From 2026-06-17 to 2026-08-05 every Upptime workflow in this repository failed on every
run, and the status page went on serving a snapshot of the last thing it knew, which was
green. 49 days. The drift check was written afterwards, and a check written after an
incident is the easiest kind to get subtly wrong, because the only state anyone has seen
it against is the broken one.

## What is tested

`cases.sh` extracts the `run:` block and the `env:` values out of the shipped workflow and
drives them against a git fixture, a stubbed `gh`, and a local server whose status code and
body each case controls. Nothing is retyped: if the workflow and the cases disagree, the
workflow wins and the cases go red.

That last point was learned the hard way here. The first version of the harness supplied
its own `MAX_DATA_AGE_H=48` instead of reading the shipped one, so raising the shipped
threshold to 999999 was invisible to every case. A test that restates the implementation's
constant is only testing its own constant.

## What proves the cases are worth anything

`mutations.sh` breaks the check fifteen ways and requires the suite to go red each time.
Several of the mutations are not hypothetical: branching on curl's exit status, and the
`|| echo 000` fallback that yields the literal `000000`, are both how the first version of
this family of checks was written in csnp-connect.

Each mutation is verified to have actually changed the file, and to have left valid YAML,
before it is run. A `perl` expression that matched nothing would leave the shipped text in
place and be recorded as caught for no reason.

## Running them

    bash test/deployment-drift/cases.sh      .github/workflows/deployment-drift.yml
    bash test/deployment-drift/mutations.sh  .github/workflows/deployment-drift.yml

They need `git`, `curl`, `jq`, `python3` and `python3-yaml`, and GNU `date`, so on macOS
run them in a container rather than natively. CI runs both on any change to the workflow
or to this directory.

## The one thing these cases cannot do

They prove the check reports correctly given a state. They cannot prove the state they are
given is one production can actually reach. The 49-day case is anchored to a real measured
outage for exactly that reason.

That gap is closed separately, and deliberately in this order: this check lands while the
monitor is still broken, so its first production run has a real 49-day staleness to detect
rather than a green tick to inherit. The version fix lands after. A check whose first
observed behaviour is a pass has not been observed.
