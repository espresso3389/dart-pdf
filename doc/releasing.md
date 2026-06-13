# Releasing to pub.dev

Merges to the `deploy` branch run the pub release workflow:

1. Run the normal analysis and package tests.
2. Read each package version from its `pubspec.yaml`.
3. Skip versions already visible on pub.dev.
4. Push one release tag per unpublished package, in dependency order.
5. Let the tag-triggered `Publish to pub.dev` workflow publish each package.

The release tag format is:

| Package | pub.dev tag pattern |
|---|---|
| `pdf_cos` | `pdf_cos-v{{version}}` |
| `pdf_test_fixtures` | `pdf_test_fixtures-v{{version}}` |
| `pdf_document` | `pdf_document-v{{version}}` |
| `pdf_graphics` | `pdf_graphics-v{{version}}` |
| `dart_pdf_editor` | `dart_pdf_editor-v{{version}}` |

Configure each package's pub.dev Admin page with repository
`ben-milanko/dart-pdf`, its package-specific tag pattern above, and the
GitHub Actions environment `pub.dev`.

The `Tag pub.dev releases` workflow needs a repository secret named
`PUB_RELEASE_TAG_TOKEN`. Use a fine-grained token or GitHub App token that can
push tags to this repository. The built-in `GITHUB_TOKEN` is intentionally not
used for tag creation because GitHub does not trigger a second workflow from
pushes made with `GITHUB_TOKEN`.
