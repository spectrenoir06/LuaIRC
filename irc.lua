--[[ 
 Lua IRC library

 Copyright (c) 2010 Jakob Ovrum

 Permission is hereby granted, free of charge, to any person
 obtaining a copy of this software and associated documentation
 files (the "Software"), to deal in the Software without
 restriction, including without limitation the rights to use,
 copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the
 Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be
 included in all copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 OTHER DEALINGS IN THE SOFTWARE.]]

local socket = require "socket"

local error = error
local setmetatable = setmetatable
local rawget = rawget
local ipairs = ipairs
local print = print
local unpack = unpack
local pairs = pairs
local string = string
local tostring = tostring
local table = table
local type = type

local coroutine = coroutine

module(...)

local function assert(b, err, errlevel)
      if not b then
         error(err, errlevel or 3)
      end
      return b
end

debug = false

local clients = {}

local meta = {}
meta.__index = meta

local meta_preconnect = {}

function meta_preconnect.__index(o, k)
         local v = rawget(meta_preconnect, k)
         if not v and meta[k] then
            error("field '"..k.."' is not accessible before connecting", 2)
         end
         return v
end

function new(user)
         local o = {}
         o.nick = assert(user.nick, "Field 'nick' is required")
         o.username = user.username or "lua"
         o.realname = user.realname or "Lua owns"
         o.socket = socket.tcp()
         o.thread = coroutine.wrap(meta.think)
         o.hooks = {}
         o.connected = false

         return setmetatable(o, meta_preconnect)
end

function think()
         local abort
         for _,o in ipairs(clients) do
             abort = o:thread()
         end
         return not abort
end

color = {
	black = 1,
	blue = 2,
	green = 3,
	red = 4,
	lightred = 5,
	purple = 6,
	brown = 7,
	yellow = 8,
	lightgreen = 9,
	navy = 10,
	cyan = 11,
	lightblue = 12,
	violet = 13,
	gray = 14,
	lightgray = 15,
	white = 16
}

local colByte = string.char(3)
setmetatable(color, {__call = function(_, text, colornum)
	colornum = type(colornum) == "string" and assert(color[colornum], "Invalid color '"..colornum.."'") or colornum
	return table.concat{colByte, tostring(colornum), text, colByte}
end})

local boldByte = string.char(2)
function bold(text)
	return boldByte..text..boldByte
end

local underlineByte = string.char(31)
function underline(text)
	return underlineByte..text..underlineByte
end

function meta:hook(name, id, f)
		 f = f or id
		 self.hooks[name] = self.hooks[name] or {}
         self.hooks[name][id] = f
end
meta_preconnect.hook = meta.hook


function meta:unhook(name, id)
		local hooks = self.hooks[name]
		assert(hooks[id], "hook ID not found")
		hooks[id] = nil
end
meta_preconnect.unhook = meta.unhook

function meta:invoke(name, ...)
         local hooks = self.hooks[name]
         if hooks then
			for id,f in pairs(hooks) do
            	f(...)
         	end
		 end
end

function meta:connect(server, port)
         port = port or 6667

         local succ, err = self.socket:connect(server, port)
         if not succ then return nil, err end

         setmetatable(self, meta)

         self:send("USER %s 0 * :%s", self.username, self.realname)
         self:send("NICK %s", self.nick)
         
         self._i = #clients + 1
         clients[self._i] = self
		
		 self.socket:settimeout(0)
         self.connected = true
         return true
end
meta_preconnect.connect = meta.connect

function meta:disconnect(message)
         local message = message or "Bye!"
         
         o:invoke("OnDisconnect", message, false)
         self:send("QUIT :%s", message)

         self:shutdown()
end

function meta:shutdown()
         self.connected = false

         self.socket:shutdown()
         self.socket:close()

         clients[self._i] = nil

         setmetatable(self, nil)
end

function meta:think()
         while true do
               local line, err = self.socket:receive("*l")
			   if not line then
		           if err ~= "timeout" then
		              self:shutdown()
		              error(err)
		              return true
		           end
			   else
 				   if debug then print(line) end
		           local prefix, cmd, params = parse(line)

		           self:handle(prefix, cmd, params)
		           
		           if not self.connected then return true end    
			   end
			   coroutine.yield()
         end
end

function parsePrefix(prefix)
         local user = {}
         if prefix then
            user.nick, user.username, user.host = prefix:match("(.*)!(.*)@(.*)")
         end
         return user
end

function parse(line)
         local colonsplit = line:find(":", 2)
         local last
         if colonsplit then
            last = line:sub(colonsplit+1)
            line = line:sub(1, colonsplit-2)
         end

         local prefix
         if line:sub(1,1) == ":" then
            local space = line:find(" ")
            prefix = line:sub(2, space-1)
            line = line:sub(space)
         end
         
         local params = {}
         local it, state, init = line:gmatch("(%S+)")
         local cmd = it(state, init)

         for sub in it, state, init do
             params[#params + 1] = sub
         end

         if last then params[#params + 1] = last end

         return prefix, cmd, params
end

local handlers = {}

handlers["PING"] = function(o, prefix, query)
         o:send("PONG :%s", query)
end

handlers["001"] = function(o)
         o:invoke("OnConnect")
end

handlers["PRIVMSG"] = function(o, prefix, channel, message)
         o:invoke("OnChat", parsePrefix(prefix), channel, message)
end

handlers["NOTICE"] = function(o, prefix, channel, message)
         o:invoke("OnNotice", parsePrefix(prefix), channel, message)
end

handlers["JOIN"] = function(o, prefix, channel)
         o:invoke("OnJoin", parsePrefix(prefix), channel)
end

handlers["PART"] = function(o, prefix, channel, reason)
         o:invoke("OnPart", parsePrefix(prefix), channel, reason)
end

handlers["ERROR"] = function(o, prefix, message)
         o:invoke("OnDisconnect", message, true)
         o:shutdown()
         error(message)
end

function meta:handle(prefix, cmd, params)
         local handler = handlers[cmd]
         if handler then
            handler(self, prefix, unpack(params))
         end
end

function meta:send(fmt, ...)
         self.socket:send(fmt:format(...) .. "\r\n")
end

function meta:sendChat(channel, fmt, ...)
         self:send("PRIVMSG %s :"..fmt, channel, ...)
end

function meta:join(channel)
         self:send("JOIN %s", channel)
end

function meta:part(channel)
         self:send("PART %s", channel)
end
