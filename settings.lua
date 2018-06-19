-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at http://mozilla.org/MPL/2.0/.

data:extend({
	{
		type = "int-setting",
		name = "modular-underground-storage-tile-capacity",
		setting_type = "runtime-global",
		default_value = 2000,
		minimum_value = 0,
		order = "a-a",
	},
	{
		type = "int-setting",
		name = "modular-underground-storage-signal-update-rate",
		setting_type = "runtime-global",
		default_value = 30,
		minimum_value = 1,
		order = "a-b",
	},
})
