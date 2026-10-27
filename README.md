# Moddashplugin

A Discourse plugin replacing the Resource-Library theme component on Medicaid Hub.

It preserves the original three-tab layout, styles, title search, category hierarchy,
See more / Show less, newest-first ordering, saved staff ordering, New Resource,
category management, edit/delete controls, and resource-topic banner/back link.
The original component is the feature and design reference:
[Resources-Lib, branch 2026-10-04](https://github.com/pushpinder6805/Resources-Lib/tree/2026-10-04).

## Why a plugin

The old component discovers a directory page plus browser-cached categories, then
requests each subcategory's topic list separately. Lazy category loading can omit
categories; many subcategories multiply the requests and partial-failure points.

The plugin discovers the full permitted tree on the server, including root-category
topics. The browser calls one library endpoint and follows signed pagination cursors
in batches of 100 resources across the selected root. For example, a tab with 250
resources in 50 categories takes three library requests, rather than 50+ category
requests. It has no hard limit on category depth or search result pages.

Every request rechecks Discourse permissions, excludes private messages, shared
drafts and category-definition topics, and sends `Cache-Control: private, no-store`.
Unlisted topics retain Discourse's staff/member visibility rules. Notification mute
preferences do not remove resources from this dedicated library.

Pagination uses creation time and topic ID, with a signed cursor bound to the user,
root and search. A snapshot maximum ID keeps newly created resources from shifting
later pages. Retry preserves already visible resources; changing tabs cancels old
loads. Staff ordering is stored in Discourse's plugin store, not the admin-only theme
settings endpoint. No user-specific demo content or shared permission cache is used.

## Compatibility and status

The minimum target is Discourse `2026.10.0-latest`. CI runs the official Discourse
plugin workflow against `7d3d93e083b41f478616fa6447b884a50911187e`, the commit reported
by Medicaid Hub's public login page when development began. That does not replace a
preview on the site's actual theme and other installed plugins.

**Development build: do not install on production until the CI checks pass and the
staging checklist below is complete.** The plugin is disabled by default.

## Installation and migration

For a standard self-hosted Discourse Docker installation:

1. In Admin → Customize → Themes, open the old Resource-Library component. Copy its
   `resource_topic_order` JSON and note `topics_per_category` and the three root IDs.
   Keep the component installed for rollback.
2. In `/var/discourse/containers/app.yml`, add this line to the existing plugin clone
   commands under `hooks: after_code: exec: cmd:`:

   ```yaml
   - git clone https://github.com/pushpinder6805/Moddashplugin.git moddashplugin
   ```

   The existing hook should run in `$home/plugins`. Do not create a second `hooks`
   mapping or replace the existing plugin entries.
3. Rebuild from `/var/discourse` with `./launcher rebuild app`.
4. In Admin → Settings, search for `moddashplugin`. Set the root IDs (default
   `10|61|197`), topics per category, and paste the copied JSON into
   `moddashplugin_legacy_topic_order` to preserve the old order.
5. Disable the old Resource-Library theme component on every active theme, then
   enable `moddashplugin_enabled`. The old component and plugin must not be enabled
   together: both register the same resource views.
6. Refresh the page and perform the checklist below on staging before production.

Hosted Discourse customers must confirm custom-plugin support with their host.
This is a server plugin, not a theme component that can be installed through the
Customize → Themes screen.

## Staging checklist

- Compare the old and new library with the same account, viewport and theme.
- Test all three roots as a regular member, moderator and administrator. Also test
  an anonymous visitor if the forum permits anonymous access.
- Verify every permitted category/resource, especially a library with over 20
  subcategories and over 100 resources. Restricted content must stay restricted.
- Test direct loads, navigation from other pages, tab changes while loading,
  topic links, the topic banner and its Back to Resource Library link.
- Search titles in nested categories. Verify newest-first order, saved staff order,
  See more / Show less, and saving an order as a moderator.
- Exercise New Resource, New Category (subject to Discourse's category-management
  permissions), edit and delete with suitable test resources.
- Simulate a failed later library request; verify the error and Retry controls,
  retained resources and recovery. Check desktop and mobile layouts.
- Check the browser console and Network panel for errors. Resource requests should
  use `/moddashplugin/library.json`, not one request per subcategory.

## Tests and development

The repository follows the official
[Discourse plugin skeleton](https://github.com/discourse/discourse-plugin-skeleton)
and uses the official reusable CI workflow. CI runs Ruby request specs, QUnit unit
and rendered-component tests, browser system specs and the core-features regression
suite, plus Discourse's standard Ruby/JS/SCSS linters.

Inside a Discourse development checkout with this repository at
`plugins/moddashplugin`:

```sh
LOAD_PLUGINS=1 bundle exec rspec plugins/moddashplugin/spec/requests
LOAD_PLUGINS=1 bundle exec rspec plugins/moddashplugin/spec/system
LOAD_PLUGINS=1 bin/qunit --plugins=moddashplugin
```

In this repository:

```sh
pnpm install --frozen-lockfile
pnpm lint:js
pnpm lint:css
pnpm lint:prettier
bundle install
bundle exec rubocop .
bundle exec stree check Gemfile $(git ls-files '*.rb')
```

Use a Node version supported by current Discourse tooling. No database migration,
API key, external service or background job is needed. The plugin adds only its
library and staff-order routes, configuration and plugin-store records.

## Rollback

Disable `moddashplugin_enabled`, then re-enable the old theme component. Existing
Discourse topics/categories and the old component's order setting are unchanged.
New ordering changes made in the plugin remain in its plugin store. Re-enabling
the plugin restores those orders. Removing plugin code requires another rebuild.

## License

MIT. The original Resource-Library frontend is preserved and adapted from
pushpinder6805/Resources-Lib. See `LICENSE`.
