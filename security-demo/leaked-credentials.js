/**
 * DELIBERATELY PLANTED FAKE CREDENTIALS -- exam fixture, not a real leak.
 *
 * Every value is a non-functional placeholder shaped to match a scanner rule;
 * none authenticate against anything. The `vulnerability-demo` job in
 * .github/workflows/ci.yml scans this directory and FAILS if Gitleaks does
 * NOT flag them. See ../README.md.
 */

module.exports = {
  // Gitleaks rule: github-pat
  GITHUB_TOKEN: 'ghp_1234567890abcdefghijklmnopqrstuvwxyz',

  // Gitleaks rule: private-key
  SSH_PRIVATE_KEY: '-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAxfakefakefakefakefakefakefakefakefakefake\n-----END RSA PRIVATE KEY-----',
};
