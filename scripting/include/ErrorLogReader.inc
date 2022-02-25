/*
	sourcemod ErrorLogReader Plugin Include
	
	Website: https://github.com/Ciallo-Ani/Sourcemod-ErrorLogReader
*/

#if defined _ErrorLogReader_included_
#endinput
#endif
#define _ErrorLogReader_included_



// =====[ FORWARDS ]=====

/**
 * Called when new error occurred.
 *
 * @param errorMsg					Error message.
 * @noreturn.
 */
forward void ELR_OnNewError(const char[] errorMsg);

/**
 * Called when new error finish throwing.
 *
 * @param plugin					The plugin which is blaming.
 * @param errorMsg					Error message.
 * @noreturn.
 */
forward void ELR_OnNewError_Post(const char[] plugin, ArrayList errorMsgs);



// =====[ DEPENDENCY ]=====

public SharedPlugin __pl_ErrorLogReader = 
{
	name = "ErrorLogReader", 
	file = "ErrorLogReader.smx", 
	#if defined REQUIRE_PLUGIN
	required = 1, 
	#else
	required = 0, 
	#endif
};