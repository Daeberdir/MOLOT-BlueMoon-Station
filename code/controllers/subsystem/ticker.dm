#define ROUND_START_MUSIC_LIST "strings/round_start_sounds.txt"

SUBSYSTEM_DEF(ticker)
	name = "Ticker"
	init_order = INIT_ORDER_TICKER

	priority = FIRE_PRIORITY_TICKER
	flags = SS_KEEP_TIMING
	runlevels = RUNLEVEL_LOBBY | RUNLEVEL_SETUP | RUNLEVEL_GAME

	var/current_state = GAME_STATE_STARTUP	//state of current round (used by process()) Use the defines GAME_STATE_* !
	var/force_ending = 0					//Round was ended by admin intervention
	// If true, there is no lobby phase, the game starts immediately.
	var/start_immediately = FALSE
	var/setup_done = FALSE //All game setup done including mode post setup and

	var/hide_mode = 0
	var/datum/game_mode/mode = null
	var/event_time = null
	var/event = 0

	var/login_music							//music played in pregame lobby
	var/round_end_sound						//music/jingle played when the world reboots
	var/round_end_sound_sent = TRUE			//If all clients have loaded it

	var/list/datum/mind/minds = list()		//The characters in the game. Used for objective tracking.

	var/list/syndicate_coalition = list()	//list of traitor-compatible factions
	var/list/factions = list()				//list of all factions
	var/list/availablefactions = list()		//list of factions with openings
	var/list/scripture_states = list(SCRIPTURE_DRIVER = TRUE, \
	SCRIPTURE_SCRIPT = FALSE, \
	SCRIPTURE_APPLICATION = FALSE) //list of clockcult scripture states for announcements

	var/delay_end = 0						//if set true, the round will not restart on it's own
	var/admin_delay_notice = ""				//a message to display to anyone who tries to restart the world after a delay
	var/ready_for_reboot = FALSE			//all roundend preparation done with, all that's left is reboot

	var/triai = 0							//Global holder for Triumvirate
	var/tipped = 0							//Did we broadcast the tip of the day yet?
	var/selected_tip						// What will be the tip of the day?

	var/timeLeft						//pregame timer
	var/start_at

	var/gametime_offset = 432000		//Deciseconds to add to world.time for station time.
	var/station_time_rate_multiplier = 12		//factor of station time progressal vs real time.

	var/totalPlayers = 0					//used for pregame stats on statpanel
	var/totalPlayersReady = 0				//used for pregame stats on statpanel

	var/queue_delay = 0
	var/list/queued_players = list()		//used for join queues when the server exceeds the hard population cap

	var/maprotatechecked = 0

	var/news_report

	var/late_join_disabled

	var/roundend_check_paused = FALSE

	var/round_start_time = 0
	var/list/round_start_events
	var/list/round_end_events
	var/mode_result = "undefined"
	var/end_state = "undefined"

	var/modevoted = FALSE					//Have we sent a vote for the gamemode?

	var/station_integrity = 100				// stored at roundend for use in some antag goals
	var/emergency_reason
	var/real_round_start_time = 0

	/// If the gamemode fails to be run too many times, we swap to a preset gamemode, this should give admins time to set their preferred one
	var/emergency_swap = 0

	/// People who have been commended and will receive a heart
	var/list/hearts

	// BLUEMOON ADD START - воут за карту и перезагрузка сервера, если прошлый раунд окончился крашем

	/// Was already launched map vote, after which server will be restarted?
	var/mapvote_restarter_in_progress

	/// Was SSPersistence GracefulEnding mark unrecorded due to roundstart?
	var/graceful_ending_unrecoreded = FALSE

	// BLUEMOON ADD END

/datum/controller/subsystem/ticker/Initialize(timeofday)
	load_mode()

	var/list/byond_sound_formats = list(
		"mid"  = TRUE,
		"midi" = TRUE,
		"mod"  = TRUE,
		"it"   = TRUE,
		"s3m"  = TRUE,
		"xm"   = TRUE,
		"oxm"  = TRUE,
		"wav"  = TRUE,
		"ogg"  = TRUE,
		"raw"  = TRUE,
		"wma"  = TRUE,
		"aiff" = TRUE
	)

	var/list/provisional_title_music = flist("[global.config.directory]/title_music/sounds/")
	var/list/music = list()
	var/use_rare_music = prob(1)

	for(var/S in provisional_title_music)
		var/lower = lowertext(S)
		var/list/L = splittext(lower,"+")
		switch(L.len)
			if(3) //rare+MAP+sound.ogg or MAP+rare.sound.ogg -- Rare Map-specific sounds
				if(use_rare_music)
					if(L[1] == "rare" && L[2] == SSmapping.config.map_name)
						music += S
					else if(L[2] == "rare" && L[1] == SSmapping.config.map_name)
						music += S
			if(2) //rare+sound.ogg or MAP+sound.ogg -- Rare sounds or Map-specific sounds
				if((use_rare_music && L[1] == "rare") || (L[1] == SSmapping.config.map_name))
					music += S
				else if(findtext(S, "{") && findtext(S, "}")) // Include songs with curly braces if they are part of a specific category
					music += S
			if(1) //sound.ogg -- common sound
				if(L[1] == "exclude")
					continue
				if(!findtext(S, "{") && !findtext(S, "}")) // Exclude songs surrounded by curly braces
					music += S

	var/old_login_music = trim(file2text("data/last_round_lobby_music.txt"))
	if(music.len > 1)
		music -= old_login_music

	for(var/S in music)
		var/list/L = splittext(S,".")
		if(L.len >= 2)
			var/ext = lowertext(L[L.len]) //pick the real extension, no 'honk.ogg.exe' nonsense here
			if(byond_sound_formats[ext])
				continue
		music -= S

	if(isemptylist(music))
		music = world.file2list(ROUND_START_MUSIC_LIST, "\n")
		login_music = pick(music)
	else
		// Use the sound path from the title subsystem if it exists
		if(SStitle.sound_path)
			login_music = SStitle.sound_path
		else
			login_music = "[global.config.directory]/title_music/sounds/[pick(music)]"

	if(!GLOB.syndicate_code_phrase)
		GLOB.syndicate_code_phrase	= generate_code_phrase(return_list=TRUE)

		var/codewords = jointext(GLOB.syndicate_code_phrase, "|")
		var/regex/codeword_match = new("([codewords])", "ig")

		GLOB.syndicate_code_phrase_regex = codeword_match

	if(!GLOB.syndicate_code_response)
		GLOB.syndicate_code_response = generate_code_phrase(return_list=TRUE)

		var/codewords = jointext(GLOB.syndicate_code_response, "|")
		var/regex/codeword_match = new("([codewords])", "ig")

		GLOB.syndicate_code_response_regex = codeword_match

	start_at = world.time + (CONFIG_GET(number/lobby_countdown) * 10)
	if(CONFIG_GET(flag/randomize_shift_time))
		gametime_offset = rand(0, 23) HOURS
	else if(CONFIG_GET(flag/shift_time_realtime))
		gametime_offset = world.timeofday
	return ..()

/datum/controller/subsystem/ticker/fire()
	switch(current_state)
		if(GAME_STATE_STARTUP)
			if(Master.initializations_finished_with_no_players_logged_in)
				start_at = world.time + (CONFIG_GET(number/lobby_countdown) * 10)
			for(var/client/C in GLOB.clients)
				window_flash(C, ignorepref = TRUE) //let them know lobby has opened up.
			to_chat(world, "<span class='boldnotice'>Добро пожаловать на [station_name()]!</span>")
			if(!SSpersistence.CheckGracefulEnding())
				send2chat(new /datum/tgs_message_content("Производится реролл карты в связи с крашем сервера..."), CONFIG_GET(string/chat_announce_new_game))
			else
				send2chat(new /datum/tgs_message_content("Новый раунд начинается на [SSmapping.config.map_name], голосование за режим полным ходом!"), CONFIG_GET(string/chat_announce_new_game))
			current_state = GAME_STATE_PREGAME
			//SPLURT EDIT - Bring back old panel
			//Everyone who wants to be an observer is now spawned
			create_observers()
			//SPLURT EDIT
			SEND_SIGNAL(src, COMSIG_TICKER_ENTER_PREGAME)

			fire()
		if(GAME_STATE_PREGAME)

			// BLUEMOON ADD START - воут за карту и перезагрузка сервера, если прошлый раунд окончился крашем
			if(mapvote_restarter_in_progress)
				return
			#ifndef LOWMEMORYMODE
			if(!SSpersistence.CheckGracefulEnding())
				SetTimeLeft(-1)
				start_immediately = FALSE
				mapvote_restarter_in_progress = TRUE
				var/vote_type = CONFIG_GET(string/map_vote_type)
				SSvote.initiate_vote("map","server", display = SHOW_RESULTS, votesystem = vote_type)
				to_chat(world, span_boldwarning("Активировано голосование за смену карты из-за неудачного завершения прошлого раунда. После его окончания сервер будет перезапущен."))
				return
			#endif
			// BLUEMOON ADD END

			//lobby stats for statpanels
			if(isnull(timeLeft))
				timeLeft = max(0,start_at - world.time)
			totalPlayers = 0
			totalPlayersReady = 0
			for(var/mob/dead/new_player/player in GLOB.player_list)
				++totalPlayers
				if(player.ready == PLAYER_READY_TO_PLAY)
					++totalPlayersReady

			if(start_immediately)
				timeLeft = 0
			if(!modevoted)
				var/forcemode = CONFIG_GET(string/force_gamemode)
				if(forcemode)
					force_gamemode(forcemode)
				#ifndef LOWMEMORYMODE
				if(!forcemode || (GLOB.master_mode == "dynamic" && CONFIG_GET(flag/dynamic_voting)))
					send_gamemode_vote()
				#else
				modevoted = TRUE
				SEND_SOUND(world, sound('sound/announcer/tonelow.ogg')) // Чтобы не придумывать колесо пусть будет тут
				#endif
			//countdown
			if(timeLeft < 0)
				return
			timeLeft -= wait

			if(timeLeft <= 300 && !tipped)
				send_tip_of_the_round()
				tipped = TRUE

			if(timeLeft <= 0)
				if(SSvote.mode && (SSvote.mode == "roundtype" || SSvote.mode == "dynamic" || SSvote.mode == "mode tiers"))
					SSvote.result()
					SSpersistence.SaveSavedVotes()
					for(var/client/C in SSvote.voting)
						C << browse(null, "window=vote;can_close=0")
					SSvote.reset()
				SEND_SIGNAL(src, COMSIG_TICKER_ENTER_SETTING_UP)
				current_state = GAME_STATE_SETTING_UP
				Master.SetRunLevel(RUNLEVEL_SETUP)
				if(start_immediately)
					fire()

		if(GAME_STATE_SETTING_UP)
			if(!setup())
				//setup failed
				current_state = GAME_STATE_STARTUP
				start_at = world.time + (CONFIG_GET(number/lobby_countdown) * 10)
				timeLeft = null
				Master.SetRunLevel(RUNLEVEL_LOBBY)
				SEND_SIGNAL(src, COMSIG_TICKER_ERROR_SETTING_UP)
			// BLUEMOON ADD START - пометка раунда, как ещё не завершившегося удачно
			else if(!graceful_ending_unrecoreded)
				SSpersistence.UnrecordGracefulEnding()
				graceful_ending_unrecoreded = TRUE
			// BLUEMOON ADD END

		if(GAME_STATE_PLAYING)
			mode.process(wait * 0.1)
			check_queue()
			check_maprotate()
			scripture_states = scripture_unlock_alert(scripture_states)
			//SSshuttle.autoEnd()

			if(!roundend_check_paused && mode.check_finished(force_ending) || force_ending)
				current_state = GAME_STATE_FINISHED
				toggle_ooc(TRUE) // Turn it on
				toggle_aooc(TRUE) // Turn it on
				toggle_dooc(TRUE)
				declare_completion(force_ending)
				Master.SetRunLevel(RUNLEVEL_POSTGAME)


/datum/controller/subsystem/ticker/proc/setup()
	to_chat(world, "<span class='boldannounce'>Starting game...</span>")
	var/init_start = world.timeofday
	if(emergency_swap >= 10)
		force_gamemode("Extended")	// If everything fails extended does not have hard requirements for starting, could be changed if needed.
	mode = config.pick_mode(GLOB.master_mode)
	if(!mode.can_start())
		to_chat(world, "<B>Unable to start [mode.name].</B> Not enough players, [mode.required_players] players and [mode.required_enemies] eligible antagonists needed. Reverting to pre-game lobby.")
		qdel(mode)
		mode = null
		SSjob.ResetOccupations()
		emergency_swap++
		return FALSE

	CHECK_TICK
	//Configure mode and assign player to special mode stuff
	var/can_continue = 0
	can_continue = src.mode.pre_setup()		//Choose antagonists
	CHECK_TICK
	can_continue = can_continue && SSjob.DivideOccupations(mode.required_jobs) 				//Distribute jobs
	CHECK_TICK

	if(!GLOB.Debug2)
		if(!can_continue)
			log_game("[mode.name] failed pre_setup, cause: [mode.setup_error]")
			send2adminchat("SSticker", "[mode.name] failed pre_setup, cause: [mode.setup_error]")
			message_admins("<span class='notice'>[mode.name] failed pre_setup, cause: [mode.setup_error]</span>")
			QDEL_NULL(mode)
			to_chat(world, "<B>Error setting up [GLOB.master_mode].</B> Reverting to pre-game lobby.")
			SSjob.ResetOccupations()
			emergency_swap++
			return FALSE
	else
		message_admins("<span class='notice'>DEBUG: Bypassing prestart checks...</span>")

	CHECK_TICK
	/*if(hide_mode) CIT CHANGE - comments this section out to obfuscate gamemodes. Quit self-antagging during extended just because "hurrrrr no antaggs!!!!!! i giv sec thing 2 do!!!!!!!!!" it's bullshit and everyone hates it
		var/list/modes = new
		for (var/datum/game_mode/M in runnable_modes)
			modes += M.name
		modes = sort_list(modes)
		to_chat(world, "<b>The gamemode is: secret!\nPossibilities:</B> [english_list(modes)]")
	else
		mode.announce()*/

	if(!CONFIG_GET(flag/ooc_during_round))
		toggle_ooc(FALSE) // Turn it off
		toggle_aooc(FALSE) // Turn it off

	CHECK_TICK
	GLOB.start_landmarks_list = shuffle(GLOB.start_landmarks_list) //Shuffle the order of spawn points so they dont always predictably spawn bottom-up and right-to-left
	create_characters() //Create player characters
	collect_minds()
	equip_characters()

	GLOB.data_core.manifest()

	transfer_characters()	//transfer keys to the new mobs

	for(var/I in round_start_events)
		var/datum/callback/cb = I
		cb.InvokeAsync()
	LAZYCLEARLIST(round_start_events)

	SEND_SIGNAL(src, COMSIG_TICKER_ROUND_STARTING)
	real_round_start_time = world.timeofday
	// SSautotransfer.new_shift(real_round_start_time) // BLUEMOON ADD

	log_world("Game start took [(world.timeofday - init_start)/10]s")
	round_start_time = world.time
	SSdbcore.SetRoundStart()

	to_chat(world, "<span class='notice'><B>Welcome to [station_name()], enjoy your stay!</B></span>")
	SEND_SOUND(world, sound(SSstation.announcer.get_rand_welcome_sound()))

	current_state = GAME_STATE_PLAYING
	Master.SetRunLevel(RUNLEVEL_GAME)

	if(SSevents.holidays)
		to_chat(world, "<span class='notice'>and...</span>")
		for(var/holidayname in SSevents.holidays)
			var/datum/holiday/holiday = SSevents.holidays[holidayname]
			to_chat(world, "<h4>[holiday.greet()]</h4>")

	PostSetup()
	SSshuttle.realtimeofstart = world.realtime

	return TRUE

/datum/controller/subsystem/ticker/proc/force_gamemode(gamemode)
	if(gamemode)
		if(!modevoted)
			modevoted = TRUE
		if(gamemode in config.modes)
			GLOB.master_mode = gamemode
			SSticker.save_mode(gamemode)
			message_admins("The gamemode has been set to [gamemode].")
			to_chat("The gamemode has been set to [gamemode].") //BlueMoon edit !!!
		else
			GLOB.master_mode = "Extended"
			SSticker.save_mode("Extended")
			message_admins("force_gamemode proc received an invalid gamemode, defaulting to extended.")
			to_chat("The gamemode has been set to extended.") //BlueMoon edit !!!

/datum/controller/subsystem/ticker/proc/PostSetup()
	set waitfor = FALSE
	mode.post_setup()
	GLOB.start_state = new /datum/station_state()
	GLOB.start_state.count()

	var/list/adm = get_admin_counts()
	var/list/allmins = adm["present"]
	send2adminchat("Server", "Round [GLOB.round_id ? "#[GLOB.round_id]:" : "of"] [hide_mode ? "secret":"[GLOB.master_mode]"] has started[allmins.len ? ".":" with no active admins online!"]")
	if(CONFIG_GET(string/new_round_ping))
		send2chat(new /datum/tgs_message_content("<@&[CONFIG_GET(string/new_round_ping)]> | Новый раунд стартует на [SSmapping.config.map_name]!"), CONFIG_GET(string/chat_announce_new_game))
		if(GLOB.master_mode == "Extended")
			send2chat(new /datum/tgs_message_content("<@&[CONFIG_GET(string/passive_round_ping)]> <@&[CONFIG_GET(string/agressive_round_ping)]> | Раунд [GLOB.round_id ? "#[GLOB.round_id]:" : "в режиме"] [hide_mode ? "секретном":"[GLOB.master_mode]"] стартует[allmins.len ? "!":" без администрации!!"]"), CONFIG_GET(string/chat_announce_new_game))
		else
			send2chat(new /datum/tgs_message_content("<@&[CONFIG_GET(string/active_round_ping)]> <@&[CONFIG_GET(string/agressive_round_ping)]> | Раунд [GLOB.round_id ? "#[GLOB.round_id]:" : "в режиме"] [hide_mode ? "секретном":"[GLOB.master_mode]"] стартует[allmins.len ? "!":" без администрации!!"]"), CONFIG_GET(string/chat_announce_new_game))
	setup_done = TRUE

	for(var/i in GLOB.start_landmarks_list)
		var/obj/effect/landmark/start/S = i
		if(istype(S))							//we can not runtime here. not in this important of a proc.
			S.after_round_start()
		else
			stack_trace("[S] [S.type] found in start landmarks list, which isn't a start landmark!")

	addtimer(CALLBACK(SSmapping, TYPE_PROC_REF(/datum/controller/subsystem/mapping, seedStation), TRUE), 60 SECONDS)

//These callbacks will fire after roundstart key transfer
/datum/controller/subsystem/ticker/proc/OnRoundstart(datum/callback/cb)
	if(!HasRoundStarted())
		LAZYADD(round_start_events, cb)
	else
		cb.InvokeAsync()

//These callbacks will fire before roundend report
/datum/controller/subsystem/ticker/proc/OnRoundend(datum/callback/cb)
	if(current_state >= GAME_STATE_FINISHED)
		cb.InvokeAsync()
	else
		LAZYADD(round_end_events, cb)

/datum/controller/subsystem/ticker/proc/station_explosion_detonation(atom/bomb)
	if(bomb)	//BOOM
		var/turf/epi = bomb.loc
		qdel(bomb)
		if(epi)
			explosion(epi, 512, 0, 0, 0, TRUE, TRUE, 0, TRUE)

/datum/controller/subsystem/ticker/proc/create_characters()
	for(var/mob/dead/new_player/player in GLOB.player_list)
		if(player.ready == PLAYER_READY_TO_PLAY && player.mind)
			GLOB.joined_player_list += player.ckey
			player.create_character(FALSE)
			if(player.new_character && player.client && player.client.prefs) // we cannot afford a runtime, ever
				LAZYOR(player.client.prefs.slots_joined_as, player.client.prefs.default_slot)
				LAZYOR(player.client.prefs.characters_joined_as, player.new_character.real_name)
			else
				stack_trace("WARNING: Either a player did not have a new_character, did not have a client, or did not have preferences. This is VERY bad.")
		else if(!(player.client?.prefs.toggles & TG_PLAYER_PANEL))
			player.new_player_panel()
		CHECK_TICK

/datum/controller/subsystem/ticker/proc/collect_minds()
	for(var/mob/dead/new_player/P in GLOB.player_list)
		if(P.new_character && P.new_character.mind)
			SSticker.minds += P.new_character.mind
		CHECK_TICK


/datum/controller/subsystem/ticker/proc/equip_characters()
	var/captainless=1
	for(var/mob/dead/new_player/N in GLOB.player_list)
		var/mob/living/carbon/human/player = N.new_character
		if(istype(player) && player.mind && player.mind.assigned_role)
			var/datum/job/J = SSjob.GetJob(player.mind.assigned_role)
			if(J)
				J.standard_assign_skills(player.mind)
			if(player.mind.assigned_role == "Captain")
				captainless=0
			if(player.mind.assigned_role != player.mind.special_role)
				SSjob.EquipRank(N, player.mind.assigned_role, 0)
				if(CONFIG_GET(flag/roundstart_traits) && ishuman(N.new_character))
					SSquirks.AssignQuirks(N.new_character, N.client, TRUE, TRUE, SSjob.GetJob(player.mind.assigned_role), FALSE, N)
				//sandstorm change
				if(ishuman(N.new_character))
					SSlanguage.AssignLanguage(N.new_character, N.client)
				//
			N.client.prefs.post_copy_to(player)
		CHECK_TICK
	if(captainless)
		for(var/mob/dead/new_player/N in GLOB.player_list)
			if(N.new_character)
				to_chat(N, "Captainship not forced on anyone.")
			CHECK_TICK

/datum/controller/subsystem/ticker/proc/transfer_characters()
	var/list/livings = list()
	for(var/mob/dead/new_player/player in GLOB.mob_list)
		var/mob/living = player.transfer_character()
		if(living)
			qdel(player)
			living.mob_transforming = TRUE
			if(living.client)
				if (living.client.prefs && living.client.prefs.auto_ooc)
					if (living.client.prefs.chat_toggles & CHAT_OOC)
						living.client.prefs.chat_toggles ^= CHAT_OOC
				var/atom/movable/screen/splash/S = new(living.client, TRUE)
				S.Fade(TRUE)
				living.client.init_verbs()
			livings += living
	if(livings.len)
		addtimer(CALLBACK(src, PROC_REF(release_characters), livings), 30, TIMER_CLIENT_TIME)

/datum/controller/subsystem/ticker/proc/release_characters(list/livings)
	for(var/I in livings)
		var/mob/living/L = I
		L.mob_transforming = FALSE

/datum/controller/subsystem/ticker/proc/send_tip_of_the_round()
	var/m
	if(selected_tip)
		m = selected_tip
	else
		var/list/randomtips = world.file2list("strings/tips.txt")
		var/list/memetips = world.file2list("strings/sillytips.txt")
		if(randomtips.len && prob(95))
			m = pick(randomtips)
		else if(memetips.len)
			m = pick(memetips)

	if(m)
		to_chat(world, examine_block("<span class='purple'><b>Tip of the round: </b>[html_encode(m)]</span>"))

/datum/controller/subsystem/ticker/proc/check_queue()
	var/hpc = CONFIG_GET(number/hard_popcap)
	if(!queued_players.len || !hpc)
		return

	queue_delay++
	var/mob/dead/new_player/next_in_line = queued_players[1]

	switch(queue_delay)
		if(5) //every 5 ticks check if there is a slot available
			if(living_player_count() < hpc)
				if(next_in_line && next_in_line.client)
					to_chat(next_in_line, "<span class='userdanger'>A slot has opened! You have approximately 20 seconds to join. <a href='?src=[REF(next_in_line)];late_join=override'>\>\>Join Game\<\<</a></span>")
					SEND_SOUND(next_in_line, sound('sound/misc/notice1.ogg'))
					next_in_line.LateChoices()
					return
				queued_players -= next_in_line //Client disconnected, remove he
			queue_delay = 0 //No vacancy: restart timer
		if(25 to INFINITY)  //No response from the next in line when a vacancy exists, remove he
			to_chat(next_in_line, "<span class='danger'>No response received. You have been removed from the line.</span>")
			queued_players -= next_in_line
			queue_delay = 0

/datum/controller/subsystem/ticker/proc/check_maprotate()
	if (!CONFIG_GET(flag/maprotation))
		return
	if (SSshuttle.emergency && SSshuttle.emergency.mode != SHUTTLE_ESCAPE || SSshuttle.canRecall())
		return
	if (maprotatechecked)
		return

	maprotatechecked = 1

	//map rotate chance defaults to 75% of the length of the round (in minutes)
	if (!prob((world.time/600)*CONFIG_GET(number/maprotatechancedelta)) && CONFIG_GET(flag/tgstyle_maprotation))
		return
	if(CONFIG_GET(flag/tgstyle_maprotation))
		INVOKE_ASYNC(SSmapping, TYPE_PROC_REF(/datum/controller/subsystem/mapping, maprotate))
	else
		var/vote_type = CONFIG_GET(string/map_vote_type)
		SSvote.initiate_vote("map","server", display = SHOW_RESULTS, votesystem = vote_type)

/datum/controller/subsystem/ticker/proc/HasRoundStarted()
	return current_state >= GAME_STATE_PLAYING

/datum/controller/subsystem/ticker/proc/IsRoundInProgress()
	return current_state == GAME_STATE_PLAYING

/proc/send_gamemode_vote() //CIT CHANGE - adds roundstart gamemode votes
	if(SSticker.current_state == GAME_STATE_PREGAME)
		if(SSticker.timeLeft < 900)
			SSticker.timeLeft = 900
		SSticker.modevoted = TRUE
		var/dynamic = CONFIG_GET(flag/dynamic_voting)
		if(dynamic)
			SSvote.initiate_vote("dynamic", "server", display = NONE, votesystem = SCORE_VOTING, forced = TRUE,vote_time = 20 MINUTES)
		else
			SSvote.initiate_vote("roundtype", "server", display = NONE, votesystem = PLURALITY_VOTING, forced=TRUE, \
			vote_time = SSticker.GetTimeLeft() - ROUNDTYPE_VOTE_END_PENALTY) //BLUEMOON CHANGE, WAS vote_time = (CONFIG_GET(flag/modetier_voting) ? 1 MINUTES : 20 MINUTES))

/datum/controller/subsystem/ticker/Recover()
	current_state = SSticker.current_state
	force_ending = SSticker.force_ending
	hide_mode = SSticker.hide_mode
	mode = SSticker.mode
	event_time = SSticker.event_time
	event = SSticker.event

	login_music = SSticker.login_music
	round_end_sound = SSticker.round_end_sound

	minds = SSticker.minds

	syndicate_coalition = SSticker.syndicate_coalition
	factions = SSticker.factions
	availablefactions = SSticker.availablefactions

	delay_end = SSticker.delay_end

	triai = SSticker.triai
	tipped = SSticker.tipped
	selected_tip = SSticker.selected_tip

	timeLeft = SSticker.timeLeft

	totalPlayers = SSticker.totalPlayers
	totalPlayersReady = SSticker.totalPlayersReady

	queue_delay = SSticker.queue_delay
	queued_players = SSticker.queued_players
	maprotatechecked = SSticker.maprotatechecked
	// round_start_time = SSticker.round_start_time

	queue_delay = SSticker.queue_delay
	queued_players = SSticker.queued_players
	maprotatechecked = SSticker.maprotatechecked

	modevoted = SSticker.modevoted

	switch (current_state)
		if(GAME_STATE_SETTING_UP)
			Master.SetRunLevel(RUNLEVEL_SETUP)
		if(GAME_STATE_PLAYING)
			Master.SetRunLevel(RUNLEVEL_GAME)
		if(GAME_STATE_FINISHED)
			Master.SetRunLevel(RUNLEVEL_POSTGAME)

/datum/controller/subsystem/ticker/proc/send_news_report()
	var/news_message
	var/news_source = "Новости Пакта Синие Луны"
	switch(news_report)
		if(NUKE_SYNDICATE_BASE)
			news_message = "Во время недавней попытки Рейдерского Захвата [station_name()] со стороны ИнтеКью, станции удалось уничтожить отряд тяжело вооружённых Террористов."
		if(STATION_DESTROYED_NUKE)
			news_message = "Мы хотели бы заверить всех сотрудников, что сообщения о ядерной атаке на [station_name()], поддерживаемой Оперативниками ИнтеКью, на самом деле являются мистификацией. Желаем безопасного дня!"
		if(STATION_EVACUATED)
			if(emergency_reason)
				news_message = "[station_name()] была эвакуирован после передачи следующего сигнала бедствия:\n\n[emergency_reason]"
			else
				news_message = "Экипаж [station_name()] эвакуирован в связи с неподтвержденными сообщениями об активности противника и ввиду достижения всех поставленных задач."
		if(BLOB_WIN)
			news_message = "[station_name()] была поражена неизвестной Биологической Вспышкой Пятого Уровня, в результате чего погиб весь экипаж. Не допустите, чтобы это случилось с вами! Помните, что чистое рабочее место - это безопасное рабочее место."
		if(BLOB_NUKE)
			news_message = "[station_name()] в настоящее время проходит дезактивацию после контролируемого всплеска радиации, использованного для удаления Биологической Слизи. Все сотрудники были благополучно эвакуированы до этого и сейчас наслаждаются отдыхом."
		if(BLOB_DESTROYED)
			news_message = "[station_name()] в настоящее время проходит процедуру дезактивации после уничтожения Биологической Опасности Пятого Уровня. Напоминаем, что все члены экипажа, испытывающие спазмы или вздутие живота, должны немедленно явиться в Отдел Службы Безопасности для последующего решения проблемы."
		if(CULT_ESCAPE)
			news_message = "ВНИМАНИЕ: Тревога. Группа религиозных фанатиков сбежала с [station_name()]."
		if(CULT_FAILURE)
			news_message = "В связи с ликвидацией запрещенного культа на борту [station_name()], мы хотели бы напомнить всем сотрудникам, что вероисповедание вне часовни строго запрещено и является основанием для увольнения."
		if(CULT_SUMMON)
			news_message = "Представители компании хотели бы уточнить, что [station_name()] было запланировано вывести из эксплуатации после разрушения метеоритом в начале этого года. Более ранние сообщения о неизвестном эльдрическом ужасе были сделаны по ошибке."
		if(NUKE_MISS)
			news_message = "ИнтеКью совершили террористическую атаку на [station_name()], взорвав Ядерную Боеголовку в пустом пространстве поблизости."
		if(OPERATIVES_KILLED)
			news_message = "На станции [station_name()] ведутся ремонтные работы после уничтожения экипажем Оперативников Террористической Группировки ИнтеКью."
		if(OPERATIVE_SKIRMISH)
			news_message = "Перестрелка между силами Отдела СБ и агентами ИнтеКью на борту [station_name()] закончилась тем, что обе стороны понесли потери, но в целом остались невредимы."
		if(REVS_WIN)
			news_message = "Представители Корпорации заверили инвесторов, что, несмотря на восстание профсоюза на борту [station_name()], повышения зарплаты рабочим не будет."
		if(REVS_LOSE)
			news_message = "[station_name()] быстро подавили ошибочную попытку Мятежа. Помните, что объединение в профсоюзы незаконно!"
		if(WIZARD_KILLED)
			news_message = "После гибели одного из космических магов на борту [station_name()] возникла совсем небольшая напряженность в отношениях с Федерацией."
		if(STATION_NUKED)
			news_message = "[station_name()] по неизвестным причинам активировали устройство самоуничтожения. В настоящее время предпринимаются попытки клонировать капитана, чтобы арестовать и казнить его."
		if(CLOCK_SUMMON)
			news_message = "Беспорядочные сообщения о вызове Бог-Машины и странные показания энергии с [station_name()] оказались непродуманным, хотя и тщательным розыгрышем клоуна."
		if(CLOCK_SILICONS)
			news_message = "Проект, начатый [station_name()] по модернизации своих кремниевых блоков с помощью современного оборудования, в целом оказался успешным, хотя в нарушение политики компании они до сих пор отказываются публиковать схемы."
		if(CLOCK_PROSELYTIZATION)
			news_message = "Было подтверждено, что вспышка энергии, произошедшая в районе станции [station_name()], была всего лишь испытанием нового оружия. Однако из-за неожиданной механической ошибки система связи была выведена из строя."
		if(SHUTTLE_HIJACK)
			news_message = "Во время плановой эвакуации на аварийном шаттле [station_name()] были повреждены навигационные протоколы и он сбился с курса, но вскоре был восстановлен, а все сотрудники были благополучно эвакуированы и сейчас наслаждаются отдыхом."
		if(GANG_OPERATING)
			news_message = "Пакт хотел бы заявить, что любые слухи об организации преступного сообщества на станциях типа [station_name()] являются ложью и не подлежат подражанию."
		if(GANG_DESTROYED)
			news_message = "Экипаж [station_name()] благодарит полицейский департамент Звездной Коалиции за оперативное устранение незначительной террористической угрозы для станции."

	if(SSblackbox.first_death)
		var/list/ded = SSblackbox.first_death
		if(ded.len)
			var/last_words = ded["last_words"] ? " Его последние слова: \"[ded["last_words"]]\"" : ""
			news_message += "\nNT Sanctioned Psykers засекли слабые следы человека, якобы умершего неподалеку от станции.\nЕго имя было: [ded["name"]], [ded["role"]], и умер он в [ded["area"]].[last_words]"
		else
			news_message += "\nNT Sanctioned Psykers с гордостью подтверждают сообщения о том, что в эту смену никто не умер!"

	if(news_message)
		send2otherserver(news_source, news_message,"News_Report")
		return news_message
	else
		return "С прискорбием сообщаем вам, что дело нечисто, йоу. Никто из наших репортеров не имеет ни малейшего представления о том, что могло или не могло произойти."

/datum/controller/subsystem/ticker/proc/GetTimeLeft()
	if(isnull(SSticker.timeLeft))
		return max(0, start_at - world.time)
	return timeLeft

/datum/controller/subsystem/ticker/proc/SetTimeLeft(newtime)
	if(newtime >= 0 && isnull(timeLeft))	//remember, negative means delayed
		start_at = world.time + newtime
	else
		timeLeft = newtime

/datum/controller/subsystem/ticker/proc/load_mode()
	var/mode = trim(file2text("data/mode.txt"))
	if(mode)
		GLOB.master_mode = mode
	else
		GLOB.master_mode = GLOB.dynamic_forced_extended
	log_game("Saved mode is '[GLOB.master_mode]'")

/datum/controller/subsystem/ticker/proc/save_mode(the_mode)
	var/F = file("data/mode.txt")
	fdel(F)
	WRITE_FILE(F, the_mode)

/datum/controller/subsystem/ticker/proc/SetRoundEndSound(the_sound)
	set waitfor = FALSE
	round_end_sound_sent = FALSE
	round_end_sound = fcopy_rsc(the_sound)
	for(var/thing in GLOB.clients)
		var/client/C = thing
		if (!C)
			continue
		C.Export("##action=load_rsc", round_end_sound)
	round_end_sound_sent = TRUE

/datum/controller/subsystem/ticker/proc/Reboot(reason, end_string, delay)
	set waitfor = FALSE
	if(usr && !check_rights(R_SERVER, TRUE))
		return

	if(!delay)
		delay = CONFIG_GET(number/round_end_countdown) * 10

	var/skip_delay = check_rights()
	if(delay_end && !skip_delay)
		to_chat(world, "<span class='boldwarning'>An admin has delayed the round end.</span>")
		return

	to_chat(world, "<span class='boldannounce'>Rebooting World in [DisplayTimeText(delay)]. [reason]</span>")

	var/start_wait = world.time
	UNTIL(round_end_sound_sent || (world.time - start_wait) > (delay * 2))	//don't wait forever
	sleep(delay - (world.time - start_wait))

	if(delay_end && !skip_delay)
		to_chat(world, "<span class='boldannounce'>Reboot was cancelled by an admin.</span>")
		return
	if(end_string)
		end_state = end_string

	var/statspage = CONFIG_GET(string/roundstatsurl)
	var/gamelogloc = CONFIG_GET(string/gamelogurl)
	if(statspage)
		to_chat(world, "<span class='info'>Round statistics and logs can be viewed <a href=\"[statspage][GLOB.round_id]\">at this website!</a></span>")
	else if(gamelogloc)
		to_chat(world, "<span class='info'>Round logs can be located <a href=\"[gamelogloc]\">at this website!</a></span>")

	log_game("<span class='boldannounce'>Rebooting World. [reason]</span>")

	world.Reboot()

/datum/controller/subsystem/ticker/Shutdown()
	gather_newscaster() //called here so we ensure the log is created even upon admin reboot
	save_admin_data()
	update_everything_flag_in_db()
	if(!round_end_sound)
		round_end_sound = pick(\
		'modular_splurt/sound/roundend/dotheballsgo.ogg',
		'modular_splurt/sound/roundend/filledwith.ogg',
		'modular_splurt/sound/roundend/iknowwhat.ogg',
		'modular_splurt/sound/roundend/lottawords.ogg',
		'modular_splurt/sound/roundend/pissesonme.ogg',
		'modular_splurt/sound/roundend/theballsgothard.ogg',
		'modular_splurt/sound/roundend/iwishtherewassomethingmore.ogg',
		'modular_splurt/sound/roundend/likeisaid.ogg',
		'modular_splurt/sound/roundend/whatarottenwaytodie.ogg',
		'modular_splurt/sound/roundend/whatashame.ogg',
		'sound/roundend/newroundsexy.ogg',
		'sound/roundend/apcdestroyed.ogg',
		'sound/roundend/seeyoulaterokay.ogg',
		'sound/roundend/bangindonk.ogg',
		'sound/roundend/leavingtg.ogg',
		'sound/roundend/its_only_game.ogg',
		'sound/roundend/yeehaw.ogg',
		'sound/roundend/disappointed.ogg',
		'sound/roundend/gondolabridge.ogg',
		'sound/roundend/haveabeautifultime.ogg',
		'sound/roundend/CitadelStationHasSeenBetterDays.ogg',
		'sound/roundend/not_working.ogg',
		'sound/roundend/lovko_pridumal.ogg',
		'sound/roundend/punk.ogg',
		'sound/roundend/tupye.ogg',
		'sound/roundend/get_up.ogg',
		'sound/roundend/phonk_cats.ogg',
		'sound/roundend/russian_fear.ogg',
		'sound/roundend/gandon.ogg',
		'sound/roundend/approachingbaystation.ogg'\
		)

	SEND_SOUND(world, sound(round_end_sound))
	text2file(login_music, "data/last_round_lobby_music.txt")
