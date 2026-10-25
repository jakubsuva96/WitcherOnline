#pragma once

#include <filesystem>
#include <string>

// Co-op profile: with <CoopProfile>true</CoopProfile> in config.xml the game's "Documents" folder becomes
// bin\WitcherOnline\coop-profile, so the player who joins keeps settings and saves of co-op apart from their own
// game (and out of Steam Cloud). "Join LAN co-op.cmd" seeds it with copies of the player's settings.
namespace wo_profile
{
	// From DllMain, before the game first asks for Documents: redirects it if config.xml asks for it.
	// Touches nothing but config.xml and the game's import table (no shell calls under the loader lock).
	void InstallIfConfigured(const std::filesystem::path &woDir);

	// The redirected Documents folder, or empty when the co-op profile is off.
	const std::wstring &Documents();
} // namespace wo_profile
