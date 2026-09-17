# Screenshots

Drop CI evidence here after the first workflow run and link it from the root
README's [Vulnerability demonstration](../../README.md#vulnerability-demonstration)
section. Worth capturing:

- `vulnerability-demo` job summary — the rendered Trivy / Gitleaks finding tables
- `build` job summary — runtime user (`node`, uid 1000) and final image size
- A pull request with the `CI passed` check red and the merge button blocked
  (proof the branch-protection bonus is actually enforcing)
- The Security tab showing SARIF findings from Trivy and CodeQL
- A full `npm run verify` run with every check passing
