# Changelog

## [1.2.0](https://github.com/rvenutolo/renovate-config/compare/v1.1.0...v1.2.0) (2026-11-14)


### Features

* add a problems mode that files the Dashboard's problems as an issue ([3dce8e0](https://github.com/rvenutolo/renovate-config/commit/3dce8e0b2e30aaf216e7fc795fb6d200683569b8))
* close, update and silence the problems issue by the window ([aef922f](https://github.com/rvenutolo/renovate-config/commit/aef922f6d74a5cb5ace5319656ef14cb9e27b92c))
* pin the Dependency Dashboard title in the preset ([71ea629](https://github.com/rvenutolo/renovate-config/commit/71ea6295ef617ba63b6f04be2872a62631fff9e6))
* report Renovate's Dependency Dashboard problems weekly ([#11](https://github.com/rvenutolo/renovate-config/issues/11)) ([6160704](https://github.com/rvenutolo/renovate-config/commit/6160704b381ec9a7cb447c0c61852c746cacb234))
* run the problems check from the caller every Sunday ([c38e835](https://github.com/rvenutolo/renovate-config/commit/c38e835381d540138914d73ac3f72e2b2528a11d))


### Bug Fixes

* run the problems check hours before the window closes ([176cc72](https://github.com/rvenutolo/renovate-config/commit/176cc729932cc56081802cb7e1b4291a70dfae0e))
* stop job closes of the problems issue from silencing it ([12d5632](https://github.com/rvenutolo/renovate-config/commit/12d5632bc760c5a53e4fcbdda8f4be6e9455d03d))
* tighten the problems mode's listings, log link and time zone ([24dd277](https://github.com/rvenutolo/renovate-config/commit/24dd277a6d4c3db00a4dd22b6648f27741461226))
* tighten the problems mode's listings, log link and time zone ([#14](https://github.com/rvenutolo/renovate-config/issues/14)) ([16324ee](https://github.com/rvenutolo/renovate-config/commit/16324ee84c3fcdc2ed32d94a04c7b28c1d222109))

## [1.1.0](https://github.com/rvenutolo/renovate-config/compare/v1.0.0...v1.1.0) (2026-11-13)


### Features

* accept optional artifact and done fields in the issue marker ([db5ac44](https://github.com/rvenutolo/renovate-config/commit/db5ac44a8e8e8962a7ef110ad322fc786bc297f1))
* add a sweep mode that files issues for stuck Renovate PRs ([bc2bdc7](https://github.com/rvenutolo/renovate-config/commit/bc2bdc77a142f53bb8c0fc3c94f3e3000fbf08f0))
* close issues for closed or no-longer-stuck PRs during the sweep ([d0490e4](https://github.com/rvenutolo/renovate-config/commit/d0490e4a2434a965e51d8c1833374f365425a7d4))
* report CI, mergeability and artifact problems in stuck issues ([ec6a889](https://github.com/rvenutolo/renovate-config/commit/ec6a88928f66fe6feac43ce7ded63cc8aa68427c))
* report Renovate PRs that are stuck after the update window ([#8](https://github.com/rvenutolo/renovate-config/issues/8)) ([b90fd74](https://github.com/rvenutolo/renovate-config/commit/b90fd74ba23c158ad785b6b12af60af3372365ad))
* run the stuck-PR sweep weekly from the caller workflow ([08012c0](https://github.com/rvenutolo/renovate-config/commit/08012c09278e4553a008b9424636b16016576aaa))


### Bug Fixes

* stop the sweep hiding failed lookups or halting on a missing PR ([2518847](https://github.com/rvenutolo/renovate-config/commit/25188477c218a535e23daa11b15b02bb118f1189))

## 1.0.0 (2026-11-12)


### Features

* add reusable failure-issue workflow and consumer examples ([7f97c3d](https://github.com/rvenutolo/renovate-config/commit/7f97c3d4ea84d195865803fb2f5c21ca46a2ec57))
* add script that files issues for failed Renovate PRs ([04613d5](https://github.com/rvenutolo/renovate-config/commit/04613d541a98e9105ff48494a885c72ba1e93089))
* add shared Renovate preset ([66718f4](https://github.com/rvenutolo/renovate-config/commit/66718f4a18efffecf52ea22ee4e9a946675330f0))


### Bug Fixes

* allow job-log downloads through the egress block ([6c3dd94](https://github.com/rvenutolo/renovate-config/commit/6c3dd94212e6c27e85176f0033d921793c6f9ef6))
* converge failure issues when a close run is lost ([d37d003](https://github.com/rvenutolo/renovate-config/commit/d37d0035f546f424916cbffec1c9c4a2ff992d29))
* keep 150 log lines and strip ANSI codes from failure issues ([c47227a](https://github.com/rvenutolo/renovate-config/commit/c47227af1f9fdc4556a823a65fd2c069f0541387))
* let release PRs pass with release-please's manifest ([1dd86a1](https://github.com/rvenutolo/renovate-config/commit/1dd86a115c9acd1e31f33cf201ce2223de1c5dfb))
* let release PRs pass with release-please's manifest ([#5](https://github.com/rvenutolo/renovate-config/issues/5)) ([ad96c83](https://github.com/rvenutolo/renovate-config/commit/ad96c835953511b704d0f2ed1fac643b41031a5b))
* never hold timestamp-less updates of any type ([0e91d8a](https://github.com/rvenutolo/renovate-config/commit/0e91d8a6bcc40838bf7ea131e43a0437142a01fb))
* skip release-please's CHANGELOG.md in format and lint checks ([b83a6f1](https://github.com/rvenutolo/renovate-config/commit/b83a6f1fbd80617ddb85197f5d3843da2106d1e0))
* skip release-please's CHANGELOG.md in format and lint checks ([#4](https://github.com/rvenutolo/renovate-config/issues/4)) ([36d0f10](https://github.com/rvenutolo/renovate-config/commit/36d0f109c293528122718a16b8cd9dfd5b2b9eab))
