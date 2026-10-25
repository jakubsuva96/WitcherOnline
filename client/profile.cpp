#include "profile.h"
#include "pch.h"

#include <windows.h>

#include <knownfolders.h>
#include <objbase.h>
#include <shlobj.h>

#include <cstring>

#include "pugixml\pugixml.hpp"

#pragma comment(lib, "ole32.lib")

namespace fs = std::filesystem;

namespace wo_profile
{
	static std::wstring g_documents;

	using SHGetKnownFolderPathFn = HRESULT(WINAPI *)(REFKNOWNFOLDERID, DWORD, HANDLE, PWSTR *);
	using SHGetFolderPathWFn = HRESULT(WINAPI *)(HWND, int, HANDLE, DWORD, LPWSTR);
	using SHGetFolderPathAFn = HRESULT(WINAPI *)(HWND, int, HANDLE, DWORD, LPSTR);
	static SHGetKnownFolderPathFn g_shGetKnownFolderPath = nullptr;
	static SHGetFolderPathWFn g_shGetFolderPathW = nullptr;
	static SHGetFolderPathAFn g_shGetFolderPathA = nullptr;

	// the same redirection the test harness's ASI uses for its sandboxes (w3test.cpp)
	static HRESULT WINAPI HookSHGetKnownFolderPath(REFKNOWNFOLDERID id, DWORD flags, HANDLE token, PWSTR *path)
	{
		if (!IsEqualGUID(id, FOLDERID_Documents) || !path)
			return g_shGetKnownFolderPath(id, flags, token, path);

		const size_t bytes = (g_documents.size() + 1) * sizeof(wchar_t);
		*path = static_cast<PWSTR>(CoTaskMemAlloc(bytes));
		if (!*path)
			return E_OUTOFMEMORY;
		memcpy(*path, g_documents.c_str(), bytes);
		return S_OK;
	}

	static HRESULT WINAPI HookSHGetFolderPathW(HWND owner, int folder, HANDLE token, DWORD flags, LPWSTR path)
	{
		if ((folder & 0xFF) != CSIDL_PERSONAL || !path || g_documents.size() >= MAX_PATH)
			return g_shGetFolderPathW(owner, folder, token, flags, path);

		wcscpy_s(path, MAX_PATH, g_documents.c_str());
		return S_OK;
	}

	static HRESULT WINAPI HookSHGetFolderPathA(HWND owner, int folder, HANDLE token, DWORD flags, LPSTR path)
	{
		if ((folder & 0xFF) != CSIDL_PERSONAL || !path)
			return g_shGetFolderPathA(owner, folder, token, flags, path);

		if (!WideCharToMultiByte(CP_ACP, 0, g_documents.c_str(), -1, path, MAX_PATH, nullptr, nullptr))
			return E_FAIL;
		return S_OK;
	}

	static bool PatchImport(HMODULE module, const char *dll, const char *function, void *hook, void **original)
	{
		auto *base = reinterpret_cast<uint8_t *>(module);
		const auto *dos = reinterpret_cast<IMAGE_DOS_HEADER *>(base);
		const auto *nt = reinterpret_cast<IMAGE_NT_HEADERS *>(base + dos->e_lfanew);
		const IMAGE_DATA_DIRECTORY &dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
		if (!dir.VirtualAddress)
			return false;

		for (auto *desc = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR *>(base + dir.VirtualAddress); desc->Name; ++desc)
		{
			if (_stricmp(reinterpret_cast<char *>(base + desc->Name), dll) != 0)
				continue;

			auto *names = reinterpret_cast<IMAGE_THUNK_DATA *>(base + (desc->OriginalFirstThunk ? desc->OriginalFirstThunk : desc->FirstThunk));
			auto *slots = reinterpret_cast<IMAGE_THUNK_DATA *>(base + desc->FirstThunk);
			for (; names->u1.AddressOfData; ++names, ++slots)
			{
				if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal))
					continue;
				const auto *byName = reinterpret_cast<IMAGE_IMPORT_BY_NAME *>(base + names->u1.AddressOfData);
				if (strcmp(byName->Name, function) != 0)
					continue;

				DWORD protection = 0;
				VirtualProtect(&slots->u1.Function, sizeof(void *), PAGE_READWRITE, &protection);
				*original = reinterpret_cast<void *>(slots->u1.Function);
				slots->u1.Function = reinterpret_cast<ULONG_PTR>(hook);
				VirtualProtect(&slots->u1.Function, sizeof(void *), protection, &protection);
				return true;
			}
		}
		return false;
	}

	template <typename Fn>
	static bool Hook(HMODULE module, const char *function, Fn hook, Fn &original)
	{
		void *previous = nullptr;
		const bool ok = PatchImport(module, "SHELL32.dll", function, reinterpret_cast<void *>(hook), &previous);
		original = reinterpret_cast<Fn>(previous);
		return ok;
	}

	void InstallIfConfigured(const fs::path &woDir)
	{
		try
		{
			pugi::xml_document doc;
			if (!doc.load_file((woDir / "config.xml").c_str()))
				return;
			if (!doc.child("Config").child("CoopProfile").text().as_bool(false))
				return;

			const fs::path documents = woDir / "coop-profile";
			std::error_code ec;
			fs::create_directories(documents / "The Witcher 3" / "gamesaves", ec);

			// set before the hooks go in: they read it
			g_documents = documents.wstring();
			HMODULE game = GetModuleHandleW(nullptr);
			const bool known = Hook(game, "SHGetKnownFolderPath", &HookSHGetKnownFolderPath, g_shGetKnownFolderPath);
			const bool wide = Hook(game, "SHGetFolderPathW", &HookSHGetFolderPathW, g_shGetFolderPathW);
			const bool narrow = Hook(game, "SHGetFolderPathA", &HookSHGetFolderPathA, g_shGetFolderPathA);
			if (!known && !wide && !narrow)
				g_documents.clear();
		}
		catch (...)
		{
			g_documents.clear();
		}
	}

	const std::wstring &Documents()
	{
		return g_documents;
	}
} // namespace wo_profile
