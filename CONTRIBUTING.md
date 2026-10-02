# Contributing

Use CRuby 3.3 or later. Run `bundle install`, `bundle exec rake`, `bundle exec rubocop`, `bundle exec bundler-audit check --update` and `bundle exec rake build`. Run the complete suite on Linux for forked-process and OTLP/HTTP integration coverage.

Development uses Git dependencies for gritz-core and gritz-native. To use sibling checkouts:

```sh
bundle config set --local local.gritz-core ../gritz-core
bundle config set --local local.gritz-native ../gritz-native
bundle config set --local disable_local_branch_check true
bundle install
```

Write a failing behavior test before changing nontrivial logic. Keep optional integrations outside gritz-core and transport behavior in the adapter. Scaffold each new gem with `bundle gem NAME`; stop before its first publication and ask the project owner to release it and configure Trusted Publishing.

CHANGELOG contains only user-visible changes. Initial release notes are exactly `Initial release.`. Documentation, tests and tooling alone do not justify a release. See [releasing](docs/guides/releasing.md).
