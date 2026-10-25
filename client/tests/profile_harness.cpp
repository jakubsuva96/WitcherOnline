// Checks profile.cpp without the game, for lan_stage1_test.py in witcher3-coop: with <CoopProfile>true</CoopProfile>
// in <woDir>\config.xml, this process's Documents folder (as the game asks for it) becomes <woDir>\coop-profile.
// Build (x64 Developer prompt): cl /EHsc /std:c++17 /I.. profile_harness.cpp ..\profile.cpp ..\pugixml\pugixml.cpp shell32.lib
// Usage: profile_harness <woDir>   (prints the Documents folder through all three APIs)
#include "profile.h"

#include <windows.h>

#include <knownfolders.h>
#include <shlobj.h>

#include <iostream>

#pragma comment(lib, "shell32.lib")

int wmain(int argc, wchar_t **argv)
{
	if (argc < 2)
		return 2;

	wo_profile::InstallIfConfigured(argv[1]);

	PWSTR known = nullptr;
	SHGetKnownFolderPath(FOLDERID_Documents, 0, nullptr, &known);
	wchar_t wide[MAX_PATH]{};
	SHGetFolderPathW(nullptr, CSIDL_PERSONAL, nullptr, 0, wide);
	char narrow[MAX_PATH]{};
	SHGetFolderPathA(nullptr, CSIDL_PERSONAL, nullptr, 0, narrow);

	std::wcout << L"known=" << (known ? known : L"") << L"\n";
	std::wcout << L"wide=" << wide << L"\n";
	std::cout << "narrow=" << narrow << "\n";
	std::wcout << L"profile=" << wo_profile::Documents() << L"\n";
	CoTaskMemFree(known);
	return 0;
}
