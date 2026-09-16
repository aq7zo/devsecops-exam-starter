/**
 * DELIBERATELY PLANTED FAKE CREDENTIALS -- exam fixture, not a real leak.
 *
 * Both values below are CONFIRMED detected by the CI run, not merely assumed
 * to match a rule. An AWS key pair was planted here originally and removed:
 * see the "credential that was too fake" note in ../README.md.
 *
 * Required by the exam spec: "deliberately commit a 'fake' API key ...
 * demonstrate how your pipeline successfully detects and flags this".
 *
 * Every value below is a non-functional placeholder that matches the shape a
 * secret scanner looks for. The AWS pair is the published example pair from
 * Amazon's own documentation; the others are random strings in the right
 * format. None of them authenticate against anything.
 *
 * The `vulnerability-demo` job in .github/workflows/ci.yml scans this
 * directory and FAILS if Gitleaks does NOT flag it. See ../README.md.
 */

module.exports = {
  // Gitleaks rule: github-pat
  GITHUB_TOKEN: 'ghp_1234567890abcdefghijklmnopqrstuvwxyz',

  // Gitleaks rule: private-key
  SSH_PRIVATE_KEY: '-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAxfakefakefakefakefakefakefakefakefakefake\n-----END RSA PRIVATE KEY-----',
};
