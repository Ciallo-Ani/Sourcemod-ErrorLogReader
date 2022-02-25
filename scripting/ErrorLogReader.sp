/*
 * based on https://github.com/rob5300/sm-sentry-error-logger
*/

#include <sourcemod>
#include <convar_class>
#include <ErrorLogReader>

#pragma newdecls required
#pragma semicolon 1



#define ERROR_DATETIME_LEN 25

static const char gS_IgnoreErrorStrings[][] = 
{
	"SourceMod error session started",
	"Error log file session closed",
};

char gS_ErrorLogPath[PLATFORM_MAX_PATH];

int gI_FileLastPosition = 0;
int gI_ErrorLastTime = -1;
int gI_ErrorFirstExistTime = -1;

Handle gH_ProcessWaitTimer = null;

Convar gCV_ReaderWaitTime = null;
Convar gCV_ErrorWaitTime = null;

GlobalForward gH_Forward_OnNewError = null;
GlobalForward gH_Forward_OnNewError_Post = null;



public void OnPluginStart()
{
	gH_Forward_OnNewError = new GlobalForward("ELR_OnNewError", ET_Ignore, Param_String);
	gH_Forward_OnNewError_Post = new GlobalForward("ELR_OnNewError_Post", ET_Ignore, Param_String, Param_Cell);

	gCV_ReaderWaitTime = new Convar("sm_elr_waittime", "120", "Time to wait for error log listening.");
	gCV_ErrorWaitTime = new Convar("sm_elr_error_waittime", "2", "Time to wait for next error reading, used to skip unlessly blaming.");
	Convar.AutoExecConfig();

	gCV_ReaderWaitTime.AddChangeHook(OnConvarChanged);

	DoSetup();
}

public void OnConvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	delete gH_ProcessWaitTimer;
	gH_ProcessWaitTimer = CreateTimer(StringToFloat(newValue), Timer_ProcessErrorLog, _, TIMER_REPEAT);
}

bool DoSetup()
{
	char newestErrorLogPath[PLATFORM_MAX_PATH];
	strcopy(newestErrorLogPath, sizeof(newestErrorLogPath), GetLatestErrorLogPath());

	if (!FileExists(newestErrorLogPath))
	{
		SetFailState("ErrorLogReader setup failed. Path not exist: %s", newestErrorLogPath);
		return false;
	}

	File errorLog = OpenFile(newestErrorLogPath, "r");

	if(errorLog == null)
	{
		delete errorLog;
		SetFailState("ErrorLogReader setup failed. Open file %s failed", newestErrorLogPath);
		return false;
	}

	strcopy(gS_ErrorLogPath, sizeof(gS_ErrorLogPath), newestErrorLogPath);

	gH_ProcessWaitTimer = CreateTimer(gCV_ReaderWaitTime.FloatValue, Timer_ProcessErrorLog, _, TIMER_REPEAT);

	delete errorLog;
	return true;
}

public Action Timer_ProcessErrorLog(Handle timer)
{
	if(strlen(gS_ErrorLogPath) == 0)
	{
		PrepareNextLog();
		return Plugin_Continue;
	}

	File errorLog = OpenFile(gS_ErrorLogPath, "r");
	if(errorLog == null)
	{
		delete errorLog;
		PrintToServer("Recent error log file deleted, listening next");
		PrepareNextLog();
		return Plugin_Continue;
	}

	ArrayList aErrorContents = new ArrayList();
	char sPluginBlaming[32];

	char line[512];
	errorLog.Seek(gI_FileLastPosition, SEEK_SET);
	while(!errorLog.EndOfFile() && errorLog.ReadLine(line, sizeof(line)))
	{
		if(strlen(line) > ERROR_DATETIME_LEN)
		{
			// Store the current file position
			gI_FileLastPosition = errorLog.Position;

			// Get the date+time component
			char dateTimeStr[ERROR_DATETIME_LEN];
			SubStr(dateTimeStr, line, 0, ERROR_DATETIME_LEN);

			// Skip unlessly blaming
			if(SkipUnlesslyBlaming(dateTimeStr))
			{
				continue;
			}

			// Get the error message component
			char errorContents[512];
			SubStr(errorContents, line, ERROR_DATETIME_LEN, strlen(line));

			// Log this error if this error was not already seen, and if the error doesnt have the ignored strings in it.
			if (!ContainsIgnoredStrings(errorContents))
			{
				Call_OnNewError(errorContents);
				aErrorContents.PushString(errorContents);
				GetBlamingPlugin(sPluginBlaming, errorContents);
			}
		}
	}

	if(strlen(sPluginBlaming) != 0)
	{
		Call_OnNewError_Post(sPluginBlaming, aErrorContents);
	}

	delete errorLog;
	delete aErrorContents;

	PrepareNextLog();

	return Plugin_Continue;
}

bool SkipUnlesslyBlaming(const char[] time)
{
	int currentTime = GetTimeFromStr(time);
	if(gI_ErrorLastTime == -1)
	{
		gI_ErrorLastTime = currentTime;
		gI_ErrorFirstExistTime = currentTime;
	}

	int diff = currentTime - gI_ErrorLastTime;
	if(0 < diff <= gCV_ErrorWaitTime.IntValue)
	{
		gI_ErrorLastTime = currentTime;
		return true;
	}
	else if(diff == 0 && currentTime > gI_ErrorFirstExistTime)
	{
		return true;
	}

	gI_ErrorLastTime = currentTime;
	gI_ErrorFirstExistTime = currentTime;

	return false;
}

void PrepareNextLog()
{
	char tmp[PLATFORM_MAX_PATH];
	strcopy(tmp, sizeof(tmp), GetLatestErrorLogPath());
	if(strlen(tmp) == 0)
	{
		return;
	}

	if(!StrEqual(gS_ErrorLogPath, tmp, false))
	{
		gI_FileLastPosition = 0;
		gI_ErrorLastTime = -1;
		gI_ErrorFirstExistTime = -1;

		strcopy(gS_ErrorLogPath, sizeof(gS_ErrorLogPath), tmp);
	}
}

bool ContainsIgnoredStrings(const char[] str)
{
	for(int i = 0; i < sizeof(gS_IgnoreErrorStrings); i++)
	{
		if((StrContains(str, gS_IgnoreErrorStrings[i], false) != -1))
		{
			return true;
		}
	}

	return false;
}

char[] GetLatestErrorLogPath()
{
	char sLogPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sLogPath, sizeof(sLogPath), "logs/");

	DirectoryListing dir = OpenDirectory(sLogPath);
	if(dir == null)
	{
		delete dir;
		SetFailState("Failed to open SM logs dir -> %s", sLogPath);
		return sLogPath;
	}

	int lastModifyTime = -1;
	char sLogs[PLATFORM_MAX_PATH];
	char sErrorLogPath[PLATFORM_MAX_PATH];
	FileType type = FileType_Unknown;
	bool haveErrorLog = false;
	while(dir.GetNext(sLogs, sizeof(sLogs), type))
	{
		// Make sure this is a file + the filename has 'error' in it.
		if(type != FileType_File || StrContains(sLogs, "error", false) == -1)
		{
			continue;
		}

		haveErrorLog = true;

		char sFile[PLATFORM_MAX_PATH];
		FormatEx(sFile, sizeof(sFile), "%s%s", sLogPath, sLogs);

		int last_write_time = GetFileTime(sFile, FileTime_LastChange);
		if (lastModifyTime == -1 || last_write_time > lastModifyTime)
		{
			lastModifyTime = last_write_time;
			strcopy(sErrorLogPath, sizeof(sErrorLogPath), sLogs);
		}
	}

	delete dir;

	if(haveErrorLog)
	{
		StrCat(sLogPath, sizeof(sLogPath), sErrorLogPath);
	}
	else
	{
		StrCat(sLogPath, sizeof(sLogPath), "\0");
	}

	return sLogPath;
}

bool GetBlamingPlugin(char[] dest, const char[] src)
{
	int start = StrContains(src, "Blaming", false);
	if(start == -1)
	{
		if(GetThrowingErrorPlugin(dest, src))
		{
			return true;
		}

		return false;
	}

	SubStr(dest, src, start + 9, strlen(src) - 1);

	return true;
}

bool GetThrowingErrorPlugin(char[] dest, const char[] src)
{
	if(StrContains(src, "smx", false) == -1)
	{
		return false;
	}

	int end = FindCharInString(src, ']');

	SubStr(dest, src, 1, end);

	return true;
}

stock void SubStr(char[] dest, const char[] src, int m, int n)
{
	int count = 0;

	for (int i = m; i < n; i++)
	{
		dest[count++] = src[i];
	}

	dest[count] = '\0';
}

// get time based on seconds
stock int GetTimeFromStr(const char[] src)
{
	int start = FindCharInString(src, '-');
	int end = FindCharInString(src, ':', true);

	char sTime[10]; // should be 01:23:45
	SubStr(sTime, src, start + 2, end);

	char sBuffer[3][3]; // should be 01, 23, 45
	ExplodeString(sTime, ":", sBuffer, sizeof(sBuffer), sizeof(sBuffer[]));

	int hour = StringToInt(sBuffer[0]);
	int minute = StringToInt(sBuffer[1]);
	int second = StringToInt(sBuffer[2]);

	return hour * 60 + minute * 60 + second;
}

void Call_OnNewError(const char[] error)
{
	Call_StartForward(gH_Forward_OnNewError);
	Call_PushString(error);
	Call_Finish();
}

void Call_OnNewError_Post(const char[] plugin, ArrayList errorMsgs)
{
	Call_StartForward(gH_Forward_OnNewError_Post);
	Call_PushString(plugin);
	Call_PushCell(errorMsgs);
	Call_Finish();
}