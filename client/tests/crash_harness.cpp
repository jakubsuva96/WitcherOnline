// Drives crash.cpp without the game, for lan_stage1_test.py in witcher3-coop.
// Build (x64 Developer prompt): cl /EHsc /std:c++17 /I.. crash_harness.cpp ..\crash.cpp
// Usage: crash_harness <mode> <woDir> [host port]
//   crash   install, log a line, crash with an access violation (the handler writes a report)
//   killed  install, log a line, end without a clean exit (the next start files a "no clean exit" report)
//   clean   install, log a line, exit cleanly
//   upload  install (files reports for an unclean previous run), send pending reports to host:port, wait
#include "crash.h"
#include "NativeBridge.h"

#include <windows.h>

#include <fstream>
#include <iostream>
#include <string>
#include <thread>

namespace wo_native
{
	void DebugLog(const std::string &text)
	{
		std::cout << text << std::endl;
	}
} // namespace wo_native

int main(int argc, char **argv)
{
	if (argc < 3)
	{
		std::cerr << "usage: crash_harness crash|killed|clean|upload <woDir> [host port]\n";
		return 2;
	}

	// no Windows Error Reporting dialog when the crash mode crashes
	SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);

	const std::string mode = argv[1];
	const std::filesystem::path woDir = argv[2];
	std::filesystem::create_directories(woDir);

	wo_crash::Install(woDir, "WitcherOnline.log", {"HarnessPlayer", "0.3.0-dev", "5.0.15.65482", "127.0.0.1:40000"});
	{
		std::ofstream log(woDir / "WitcherOnline.log", std::ios::app);
		log << "harness log line for mode " << mode << "\n";
	}

	if (mode == "crash")
	{
		volatile int *nowhere = nullptr;
		*nowhere = 42;
		return 0;
	}
	if (mode == "killed")
	{
		TerminateProcess(GetCurrentProcess(), 9);
		return 9;
	}
	if (mode == "clean")
	{
		wo_crash::MarkCleanExit();
		return 0;
	}
	if (mode == "upload" && argc >= 5)
	{
		const ULONGLONG started = GetTickCount64();
		wo_crash::UploadPending(argv[3], std::stoi(argv[4]), "HarnessPlayer");
		// the upload runs on its own thread, as in the game
		while (wo_crash::IsUploading() && GetTickCount64() - started < 120000)
			std::this_thread::sleep_for(std::chrono::milliseconds(50));
		std::cout << "upload finished after " << (GetTickCount64() - started) << " ms" << std::endl;
		wo_crash::MarkCleanExit();
		// like the game: ExitProcess ends the other threads before static destructors run
		ExitProcess(0);
	}

	std::cerr << "unknown mode\n";
	return 2;
}
