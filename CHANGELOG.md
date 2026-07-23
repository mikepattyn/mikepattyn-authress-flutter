# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1] - 2026-07-23

### Fixed

- Complete web login when Authress Hosted Login redirects with `access_token` and `id_token` (not only authorization `code`)

## [0.1.0] - 2026-07-22

### Added

- Initial standalone release extracted from `flyingdarts_authress_login`
- Provider-based authentication context and state management
- Go Router integration with redirect logic and route guards
- Context extensions for auth state, user profile, and tokens
- Automatic token lifecycle management
- Secure token storage using `shared_preferences`
- Smart browser and deep-link handling
- Role and group-based access helpers
- Example app under `example/`

### Changed

- Package renamed from `authress_flutter` to `mikepattyn_authress_login` (originally extracted from `flyingdarts_authress_login`)

## Prior history (as `flyingdarts_authress_login`)

See the [flyingdarts monorepo](https://github.com/flyingdarts/flyingdarts/tree/main/packages/frontend/flutter/authress/login) for versions 0.0.2 through 0.0.4.
