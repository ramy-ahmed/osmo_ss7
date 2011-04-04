% M3UA in accordance with RFC4666 (http://tools.ietf.org/html/rfc4666)

% (C) 2011 by Harald Welte <laforge@gnumonks.org>
%
% All Rights Reserved
%
% This program is free software; you can redistribute it and/or modify
% it under the terms of the GNU Affero General Public License as
% published by the Free Software Foundation; either version 3 of the
% License, or (at your option) any later version.
%
% This program is distributed in the hope that it will be useful,
% but WITHOUT ANY WARRANTY; without even the implied warranty of
% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
% GNU General Public License for more details.
%
% You should have received a copy of the GNU Affero General Public License
% along with this program.  If not, see <http://www.gnu.org/licenses/>.

-module(m3ua_core).
-author('Harald Welte <laforge@gnumonks.org>').

-include_lib("kernel/include/inet_sctp.hrl").
-include("sccp.hrl").
-include("m3ua.hrl").

-export([start_link/1]).

-export([init/1, terminate/3, code_change/4, handle_event/3, handle_info/3]).

% FSM states:
-export([asp_down/2, asp_inactive/2, asp_active/2]).

-define(T_ACK_TIMEOUT, 2*60*100).

% Loop Data
-record(m3ua_state, {
	  role,		% asp | sgp
	  asp_state,	% down, inactive, active
	  t_ack,
	  user_pid,
	  sctp_remote_ip,
	  sctp_remote_port,
	  sctp_local_port,
	  sctp_sock,
	  sctp_assoc_id
	}).

start_link(InitOpts) ->
	gen_fsm:start_link(?MODULE, InitOpts, [{debug, [trace]}]).

reconnect_sctp(L = #m3ua_state{sctp_remote_ip = Ip, sctp_remote_port = Port, sctp_sock = Sock}) ->
	io:format("SCTP Reconnect ~p:~p~n", [Ip, Port]),
	InitMsg = #sctp_initmsg{num_ostreams = 2, max_instreams = 2},
	case gen_sctp:connect(Sock, Ip, Port, [{active, once}, {reuseaddr, true},
					       {sctp_initmsg, InitMsg}]) of
		{ok, Assoc} ->
			L#m3ua_state{sctp_assoc_id = Assoc#sctp_assoc_change.assoc_id};
		{error, Error } ->
			io:format("SCTP Error ~p, reconnecting~n", [Error]),
			reconnect_sctp(L)
	end.

init(InitOpts) ->
	OpenOptsBase = [{active, once}, {reuseaddr, true}],
	LocalPort = proplists:get_value(sctp_local_port, InitOpts),
	case LocalPort of
		undefined ->
			OpenOpts = OpenOptsBase;
		_ ->
			OpenOpts = OpenOptsBase ++ [{port, LocalPort}]
	end,
	{ok, SctpSock} = gen_sctp:open(OpenOpts),
	LoopDat = #m3ua_state{role = asp, sctp_sock = SctpSock,
				user_pid = proplists:get_value(user_pid, InitOpts),
				sctp_remote_ip = proplists:get_value(sctp_remote_ip, InitOpts),
				sctp_remote_port = proplists:get_value(sctp_remote_port, InitOpts),
				sctp_local_port = LocalPort},
	LoopDat2 = reconnect_sctp(LoopDat),
	{ok, asp_down, LoopDat2}.

terminate(Reason, _State, LoopDat) ->
	io:format("Terminating ~p (Reason: ~p)~n", [?MODULE, Reason]),
	gen_sctp:close(LoopDat#m3ua_state.sctp_sock).

code_change(_OldVsn, StateName, StateData, _Extra) ->
	{ok, StateName, StateData}.

% Helper function to send data to the SCTP peer
send_sctp_to_peer(LoopDat, PktData) when is_binary(PktData) ->
	#m3ua_state{sctp_sock = Sock, sctp_assoc_id = Assoc} = LoopDat,
	SndRcvInfo = #sctp_sndrcvinfo{assoc_id = Assoc, ppid = 3, stream = 0},
	gen_sctp:send(Sock, SndRcvInfo, PktData);

% same as above, but for un-encoded #m3ua_msg{}
send_sctp_to_peer(LoopDat, M3uaMsg) when is_record(M3uaMsg, m3ua_msg) ->
	MsgBin = m3ua_codec:encode_m3ua_msg(M3uaMsg),
	send_sctp_to_peer(LoopDat, MsgBin).

% helper to send one of the up/down/act/inact management messages + start timer
send_msg_start_tack(LoopDat, State, MsgClass, MsgType, Params) ->
	% generate and send the respective message
	Msg = #m3ua_msg{version = 1, msg_class = MsgClass, msg_type = MsgType, payload = Params},
	send_sctp_to_peer(LoopDat, Msg),
	% start T(ack) timer and wait for ASP_UP_ACK
	{ok, Tack} = timer:apply_after(?T_ACK_TIMEOUT, gen_fsm, send_event,
				 [self(), {timer_expired, t_ack, {MsgClass, MsgType, Params}}]),
	{next_state, State, LoopDat#m3ua_state{t_ack = Tack}}.



handle_event(Event, State, LoopDat) ->
	io:format("Unknown Event ~p in state ~p~n", [Event, State]),
	{next_state, State, LoopDat}.



handle_info({sctp, Socket, _RemoteIp, _RemotePort, {ANC, SAC}},
	     _State, LoopDat) when is_record(SAC, sctp_assoc_change) ->
	io:format("SCTP Assoc Change ~p ~p~n", [ANC, SAC]),
	#sctp_assoc_change{state = SacState, outbound_streams = _OutStreams,
			   inbound_streams = _InStreams, assoc_id = _AssocId} = SAC,
	case SacState of 
		comm_up ->
			% FIXME: primmitive to the user
			LoopDat2 = LoopDat;
		comm_lost ->
			LoopDat2 = reconnect_sctp(LoopDat);
		addr_unreachable ->
			LoopDat2 = reconnect_sctp(LoopDat)
	end,
	inet:setopts(Socket, [{active, once}]),
	{next_state, asp_down, LoopDat2};

handle_info({sctp, Socket, RemoteIp, RemotePort, {[Anc], Data}}, State, LoopDat) ->
	io:format("SCTP rx data: ~p ~p~n", [Anc, Data]),
	% FIXME: process incoming SCTP data 
	if Socket == LoopDat#m3ua_state.sctp_sock,
	   RemoteIp == LoopDat#m3ua_state.sctp_remote_ip,
	   RemotePort == LoopDat#m3ua_state.sctp_remote_port,
	   3 == Anc#sctp_sndrcvinfo.ppid ->
		Ret = rx_sctp(Anc, Data, State, LoopDat);
	   true ->
		io:format("unknown SCTP: ~p ~p~n", [Anc, Data]),
		Ret = {next_state, State, LoopDat}
	end,
	inet:setopts(Socket, [{active, once}]),
	Ret;

handle_info({sctp, Socket, RemoteIp, RemotePort, {_Anc, Data}}, _State, LoopDat)
					when is_record(Data, sctp_shutdown_event) ->
	io:format("SCTP remote ~p:~p shutdown~n", [RemoteIp, RemotePort]),
	inet:setopts(Socket, [{active, once}]),
	{next_state, asp_down, LoopDat}.



asp_down(#primitive{subsystem = 'M', gen_name = 'ASP_UP',
		    spec_name = request, parameters = _Params}, LoopDat) ->
	send_msg_start_tack(LoopDat, asp_down, ?M3UA_MSGC_ASPSM, ?M3UA_MSGT_ASPSM_ASPUP, []);
asp_down({timer_expired, t_ack, {?M3UA_MSGC_ASPSM, ?M3UA_MSGT_ASPSM_ASPUP, Params}}, LoopDat) ->
	send_msg_start_tack(LoopDat, asp_down, ?M3UA_MSGC_ASPSM, ?M3UA_MSGT_ASPSM_ASPUP, Params);

asp_down(#m3ua_msg{msg_class = ?M3UA_MSGC_ASPSM,
		   msg_type = ?M3UA_MSGT_ASPSM_ASPUP_ACK}, LoopDat) ->
	timer:cancel(LoopDat#m3ua_state.t_ack),
	% transition into ASP_INACTIVE
	{next_state, asp_inactive, LoopDat};

asp_down(M3uaMsg, LoopDat) when is_record(M3uaMsg, m3ua_msg) ->
	rx_m3ua(M3uaMsg, asp_down, LoopDat).


asp_inactive(#primitive{subsystem = 'M', gen_name = 'ASP_ACTIVE',
			spec_name = request, parameters = _Params}, LoopDat) ->
	send_msg_start_tack(LoopDat, asp_inactive, ?M3UA_MSGC_ASPTM, ?M3UA_MSGT_ASPTM_ASPAC,
			   [{?M3UA_IEI_TRAF_MODE_TYPE, <<0,0,0,1>>}]);

asp_inactive({timer_expired, t_ack, {?M3UA_MSGC_ASPTM, ?M3UA_MSGT_ASPTM_ASPAC, Params}}, LoopDat) ->
	send_msg_start_tack(LoopDat, asp_inactive, ?M3UA_MSGC_ASPTM, ?M3UA_MSGT_ASPTM_ASPAC, Params);

asp_inactive(#primitive{subsystem = 'M', gen_name = 'ASP_DOWN',
		      spec_name = request, parameters = _Params}, LoopDat) ->
	send_msg_start_tack(LoopDat, asp_inactive, ?M3UA_MSGC_ASPSM, ?M3UA_MSGT_ASPSM_ASPDN, []);

asp_inactive({timer_expired, t_ack, {?M3UA_MSGC_ASPSM, ?M3UA_MSGT_ASPSM_ASPDN, Params}}, LoopDat) ->
	send_msg_start_tack(LoopDat, asp_inactive, ?M3UA_MSGC_ASPSM, ?M3UA_MSGT_ASPSM_ASPDN, Params);

asp_inactive(#m3ua_msg{msg_class = ?M3UA_MSGC_ASPTM,
		       msg_type = ?M3UA_MSGT_ASPTM_ASPAC_ACK}, LoopDat) ->
	timer:cancel(LoopDat#m3ua_state.t_ack),
	% transition into ASP_ACTIVE
	% FIXME: signal this to the user
	{next_state, asp_active, LoopDat};

asp_inactive(#m3ua_msg{msg_class = ?M3UA_MSGC_ASPSM,
		       msg_type = ?M3UA_MSGT_ASPSM_ASPDN_ACK}, LoopDat) ->
	timer:cancel(LoopDat#m3ua_state.t_ack),
	% transition into ASP_DOWN
	% FIXME: signal this to the user
	{next_state, asp_down, LoopDat};

asp_inactive(M3uaMsg, LoopDat) when is_record(M3uaMsg, m3ua_msg) ->
	rx_m3ua(M3uaMsg, asp_inactive, LoopDat).



asp_active(#m3ua_msg{msg_class = ?M3UA_MSGC_ASPSM,
		     msg_type = ?M3UA_MSGT_ASPSM_ASPDN_ACK}, LoopDat) ->
	timer:cancel(LoopDat#m3ua_state.t_ack),
	% transition into ASP_DOWN
	% FIXME: signal this to the user
	{next_state, asp_down, LoopDat};

asp_active(#m3ua_msg{msg_class = ?M3UA_MSGC_ASPTM,
		     msg_type = ?M3UA_MSGT_ASPTM_ASPIA_ACK}, LoopDat) ->
	timer:cancel(LoopDat#m3ua_state.t_ack),
	% transition into ASP_INACTIVE
	% FIXME: signal this to the user
	{next_state, asp_inactive, LoopDat};

asp_active(#primitive{subsystem = 'M', gen_name = 'ASP_DOWN',
		      spec_name = request, parameters = _Params}, LoopDat) ->
	send_msg_start_tack(LoopDat, asp_active, ?M3UA_MSGC_ASPSM, ?M3UA_MSGT_ASPSM_ASPDN, []);

asp_active({timer_expired, t_ack, {?M3UA_MSGC_ASPSM, ?M3UA_MSGT_ASPSM_ASPDN, Params}}, LoopDat) ->
	send_msg_start_tack(LoopDat, asp_active, ?M3UA_MSGC_ASPSM, ?M3UA_MSGT_ASPSM_ASPDN, Params);

asp_active(#primitive{subsystem = 'M', gen_name = 'ASP_INACTIVE',
		      spec_name = request, parameters = _Params}, LoopDat) ->
	send_msg_start_tack(LoopDat, asp_active, ?M3UA_MSGC_ASPTM, ?M3UA_MSGT_ASPTM_ASPIA, []);

asp_active({timer_expired, t_ack, {?M3UA_MSGC_ASPTM, ?M3UA_MSGT_ASPTM_ASPIA, Params}}, LoopDat) ->
	send_msg_start_tack(LoopDat, asp_active, ?M3UA_MSGC_ASPTM, ?M3UA_MSGT_ASPTM_ASPIA, Params);

asp_active(#primitive{subsystem = 'MTP', gen_name = 'TRANSFER',
		      spec_name = request, parameters = Params}, LoopDat) ->
	% Send message to remote peer
	OptList = [{?M3UA_IEI_PROTOCOL_DATA, Params}],
	Msg = #m3ua_msg{version = 1, msg_class = ?M3UA_MSGC_TRANSFER,
			msg_type = ?M3UA_MSGT_XFR_DATA,
			payload = OptList},
	send_sctp_to_peer(LoopDat, Msg),
	{next_state, asp_active, LoopDat};
asp_active(#m3ua_msg{version = 1, msg_class = ?M3UA_MSGC_TRANSFER,
		     msg_type = ?M3UA_MSGT_XFR_DATA, payload = Params}, LoopDat) ->
	% FIXME: Send primitive to the user
	{next_state, asp_active, LoopDat};
asp_active(#m3ua_msg{msg_class = ?M3UA_MSGC_ASPTM,
		     msg_type = ?M3UA_MSGT_ASPTM_ASPIA_ACK}, LoopDat) ->
	timer:cancel(LoopDat#m3ua_state.t_ack),
	% transition to ASP_INACTIVE
        {next_state, asp_inactive, LoopDat};



asp_active(M3uaMsg, LoopDat) when is_record(M3uaMsg, m3ua_msg) ->
	rx_m3ua(M3uaMsg, asp_active, LoopDat).


rx_sctp(_Anc, Data, State, LoopDat) ->
	M3uaMsg = m3ua_codec:parse_m3ua_msg(Data),
	gen_fsm:send_event(self(), M3uaMsg),
	{next_state, State, LoopDat}.


rx_m3ua(Msg = #m3ua_msg{version = 1, msg_class = ?M3UA_MSGC_MGMT,
			msg_type = ?M3UA_MSGT_MGMT_NTFY}, State, LoopDat) ->
	io:format("M3UA NOTIFY~n"),
	{next_state, State, LoopDat};

rx_m3ua(Msg = #m3ua_msg{version = 1, msg_class = ?M3UA_MSGC_ASPSM,
			msg_type = ?M3UA_MSGT_ASPSM_BEAT}, State, LoopDat) ->
	% Send BEAT_ACK using the same payload as the BEAT msg
	io:format("M3UA BEAT~n"),
	send_sctp_to_peer(LoopDat, Msg#m3ua_msg{msg_type = ?M3UA_MSGT_ASPSM_BEAT_ACK}),
	{next_state, State, LoopDat};

rx_m3ua(Msg = #m3ua_msg{}, State, LoopDat) ->
	io:format("M3UA Unknown messge ~p in state ~p~n", [Msg, State]),
	{next_state, State, LoopDat}.