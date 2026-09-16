# Tkya release verification

This repository publishes release artifacts with **Sigstore keyless signing** from GitHub Actions. No private Sigstore key is stored in the repository or in GitHub Secrets.

## Verify a downloaded file

Install the [Cosign](https://docs.sigstore.dev/cosign/system_config/installation/) CLI, then download both the artifact and its matching `.sigstore.json` bundle from the GitHub Release.

PowerShell example:

```powershell
cosign verify-blob `
  --bundle .\Tkya-v1.0.1-android-arm64-v8a.apk.sigstore.json `
  --certificate-identity "https://github.com/andyhz0823/kuaifei/.github/workflows/release.yml@refs/tags/v1.0.1" `
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" `
  .\Tkya-v1.0.1-android-arm64-v8a.apk
```

For another normal tag-triggered release, replace `v1.0.1` in both the filename and the certificate identity. Verify the corresponding `.exe`, `.zip`, `SHA256SUMS.txt`, and `SIGSTORE-VERIFICATION.txt` in the same way.

For a manually dispatched release, use the exact `certificate_identity` and `certificate_oidc_issuer` recorded in the published `SIGSTORE-VERIFICATION.txt`; its Git reference can be a branch rather than the release tag.

The certificate identity binds the artifact to this repository's `release.yml` workflow and the Git reference that started the release (normally the release tag). The bundle contains the keyless signature, the short-lived Fulcio certificate, and the Rekor transparency-log proof.

## Important platform-signing distinction

- **Sigstore** proves who ran the build workflow and that the downloaded bytes match the signed artifact. It is the public, reproducible verification layer for this open-source release.
- **Android APK signing** is a separate platform requirement. A public GitHub Release is deliberately gated on the `ANDROID_*` GitHub Secrets, so the APK is signed with the stable Android release keystore and can update existing installations. Without those secrets, CI can still build an evaluation artifact using the Gradle debug key and emits `ANDROID-PLATFORM-SIGNING-WARNING.txt`, but it is not published as a public release.
- **Windows Authenticode / Smart App Control** is also separate. This open-source workflow publishes Sigstore-signed Windows files but does not claim that Windows Smart App Control will trust them. A separate trusted Authenticode certificate is required for that platform behavior.

Always verify `SHA256SUMS.txt` and the artifact's Sigstore bundle before installing.
