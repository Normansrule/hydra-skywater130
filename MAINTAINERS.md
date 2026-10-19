# Maintainers

| role | who |
|---|---|
| Maintainer and code owner | Aleksander J. Norman, [@Normansrule](https://github.com/Normansrule) |

`.github/CODEOWNERS` names the same account (`* @Normansrule`), so GitHub asks it to review every pull request.

## Access, ownership and credit are three different things

- **Collaborator**: an account with current access to this repository. The repository owner grants and removes it
  under Settings, then Collaborators. An access audit on 2026-10-18 (read-only, through the GitHub API) found one
  collaborator, @Normansrule (admin), no pending invitations, no deploy keys and no webhooks.
- **Maintainer or code owner**: the person responsible for the project and for reviewing changes. Listing someone
  here or in `CODEOWNERS` grants no access and removes none.
- **Contributor**: the author recorded on a commit. That is history, not access, and it stays as it was written;
  neither this file nor `CODEOWNERS` changes it.

## Working alone

There is one maintainer, so no branch rule requires a second approval: GitHub does not let an author approve their
own pull request, and a required review would block every change. The protections that matter are the checks:
every change goes through the repository's own test suite before it is pushed.

## Reporting a problem

Open an issue with the build, the command and its output. Security-relevant reports can go to the maintainer
privately through GitHub.
