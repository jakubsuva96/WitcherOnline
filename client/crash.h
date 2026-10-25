#pragma once

#include <filesystem>
#include <string>

// Crash reports: a minidump and the logs when the game crashes, and a report for a session that ended without a
// clean exit (frozen and killed, or a crash some other handler caught). Reports wait in
// bin\WitcherOnline\crash-reports and go to the host's server over the LAN once this game connects to it.
namespace wo_crash
{
	struct SessionInfo
	{
		std::string username;
		std::string modVersion;
		std::string gameVersion;
		std::string server;
	};

	// Call before the log is opened: keeps the previous session's log as WitcherOnline*.prev.log and, if that session
	// never exited cleanly, files a report for it. Then installs the crash handler.
	void Install(const std::filesystem::path &woDir, const std::string &logName, const SessionInfo &info);

	// The crash handler can be replaced by the game's own after startup; this puts it back in front (and chains on).
	void Reinstall();

	// Called from DLL_PROCESS_DETACH: the session ended cleanly, nothing to report.
	void MarkCleanExit();

	// Sends every report not sent yet to http://host:port/crash on a background thread.
	void UploadPending(const std::string &host, int port, const std::string &username);
	bool IsUploading();
} // namespace wo_crash
