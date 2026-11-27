--[[
    STR Translator - MoonLoader (SA-MP)
    Penerjemah chat otomatis pakai AI: Gemini (utama) -> Groq (cadangan).

    Perintah:
      /str        buka / tutup menu
      /str on     nyalakan penerjemah
      /str off    matikan penerjemah  (/str of juga bisa)
      /str fokus  mode fokus on/off (tempat ramai: hanya pemain tertentu)
      /str add ID / /str del ID / /str list / /str clear   atur daftar fokus

    Kebutuhan (taruh di folder moonloader/lib):
      - SAMP.Lua (lib.samp.events)
      - mimgui
      - effil
      - lua-requests (requests) + luasocket + luasec (ssl)  -> untuk HTTPS
      - encoding

    API: Gemini (aistudio.google.com) dan Groq (console.groq.com, key diawali gsk_)
]]

script_name('STR Translator')
script_author('bobwan-pixel')
script_version('1.4')

require 'lib.moonloader'
local sampev   = require 'lib.samp.events'
local imgui    = require 'mimgui'
local encoding = require 'encoding'
local effil    = require 'effil'
local ffi      = require 'ffi'

encoding.default = 'CP1251'
local u8 = encoding.UTF8

local new, ffistr, sizeof = imgui.new, ffi.string, ffi.sizeof

-- =========================================================================
-- Bahasa
-- =========================================================================
local LANGS = {
    { label = 'Indonesia',        name = 'Indonesian' },
    { label = 'Inggris',          name = 'English' },
    { label = 'Melayu',           name = 'Malay' },
    { label = 'Filipina',         name = 'Filipino (Tagalog)' },
    { label = 'Spanyol',          name = 'Spanish' },
    { label = 'Portugis',         name = 'Portuguese' },
    { label = 'Prancis',          name = 'French' },
    { label = 'Jerman',           name = 'German' },
    { label = 'Italia',           name = 'Italian' },
    { label = 'Belanda',          name = 'Dutch' },
    { label = 'Turki',            name = 'Turkish' },
    { label = 'Polandia',         name = 'Polish' },
    { label = 'Rusia',            name = 'Russian' },
    -- gaya bahasa (ditaruh di akhir supaya pilihan lama di config tidak bergeser)
    { label = 'Inggris slang jalanan US', name = 'English',
      style = 'Write it like casual American street slang / hood talk (words like bro, ain\'t, finna, y\'all, deadass, lowkey, fr, cuz), the way young people talk on the streets in the US. Keep it natural and easy to understand, do not overdo it.' },
    { label = 'Spanyol Meksiko (slang)', name = 'Mexican Spanish',
      style = 'Write it like casual Mexican street Spanish with Mexican slang (words like wey, neta, chido, que onda, orale, carnal, no manches), the way people talk on the streets in Mexico. Keep it natural, do not overdo it.' },
}
local langLabels = {}
for i, l in ipairs(LANGS) do langLabels[i] = l.label end

-- =========================================================================
-- Konfigurasi
-- =========================================================================
local CFG_DIR  = getWorkingDirectory() .. '\\config'
local CFG_PATH = CFG_DIR .. '\\str_translator.json'

local cfg = {
    enabled          = true,
    translate_out    = true,    -- terjemahkan pesan yang aku ketik
    translate_in     = true,    -- terjemahkan pesan lawan bicara
    translate_server = true,    -- baca chat dari pesan server (format "Nama says: ...")
    translate_cmds   = false,   -- terjemahkan juga perintah seperti /b /s /low
    cmd_list         = 'b,s,low,shout,me,do',
    out_lang         = 2,       -- index LANGS (1-based) -> Inggris
    in_lang          = 1,       -- index LANGS (1-based) -> Indonesia
    raw_prefix       = '.',     -- awali pesan dengan ini untuk kirim TANPA diterjemahkan
    min_letters      = 3,
    gemini_key       = '',
    gemini_model     = 'gemini-3.5-flash-lite',
    groq_key         = '',
    groq_model       = 'openai/gpt-oss-20b',
    max_rpm          = 20,      -- batas request per menit untuk pesan lawan (hindari 429)
    skip_indo        = true,    -- pesan lawan yang jelas bahasa Indonesia tidak dikirim ke AI
    focus_mode       = false,   -- mode fokus: hanya terjemahkan pemain yang difokuskan
    focus_names      = '',      -- daftar fokus manual (nickname, dipisah koma)
    focus_auto_talk  = true,    -- fokus otomatis ke pemain di dekatmu saat kamu chat
    focus_radius     = 5,       -- meter
    focus_auto_target= true,    -- fokus otomatis ke pemain yang kamu bidik/target
    focus_auto_min   = 3,       -- menit fokus otomatis berlaku
    focus_notify     = true,    -- kabari di chat saat ada fokus otomatis baru
    cfg_version      = 3,
    debug            = false,   -- tampilkan jawaban mentah AI di chat
}

local function loadCfg()
    if not doesFileExist(CFG_PATH) then return end
    local f = io.open(CFG_PATH, 'r')
    if not f then return end
    local raw = f:read('*a')
    f:close()
    local ok, t = pcall(decodeJson, raw)
    local oldVersion = 0
    if ok and type(t) == 'table' then
        oldVersion = tonumber(t.cfg_version) or 0
        for k, v in pairs(t) do
            if cfg[k] ~= nil and type(v) == type(cfg[k]) then cfg[k] = v end
        end
    end
    -- versi 3: gpt-oss-120b diganti gpt-oss-20b (jauh lebih cepat)
    if oldVersion < 3 and cfg.groq_model == 'openai/gpt-oss-120b' then cfg.groq_model = 'openai/gpt-oss-20b' end
    cfg.cfg_version = 3
    if cfg.max_rpm < 1 then cfg.max_rpm = 20 end
    cfg.gemini_key = cfg.gemini_key:gsub('%s', '')
    cfg.groq_key = cfg.groq_key:gsub('%s', '')
    -- model Groq lama yang sudah dimatikan -> ganti otomatis
    local deadGroq = { ['llama-3.3-70b-versatile'] = false, ['llama-3.1-8b-instant'] = true,
                       ['qwen/qwen3-32b'] = true, ['meta-llama/llama-4-scout-17b-16e-instruct'] = true }
    if deadGroq[cfg.groq_model] then cfg.groq_model = 'openai/gpt-oss-20b' end
    if not LANGS[cfg.out_lang] then cfg.out_lang = 2 end
    if not LANGS[cfg.in_lang] then cfg.in_lang = 1 end
end

local function saveCfg()
    if not doesDirectoryExist(CFG_DIR) then createDirectory(CFG_DIR) end
    local f = io.open(CFG_PATH, 'w')
    if f then
        f:write(encodeJson(cfg))
        f:close()
    end
end

local dirty = false
local function markDirty() dirty = true end

-- =========================================================================
-- Utilitas
-- =========================================================================
local TAG = '{66CCFF}[STR]{FFFFFF} '

local function notify(text)
    sampAddChatMessage(TAG .. text, -1)
end

local function trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function countLetters(s)
    local n = 0
    for _ in s:gmatch('%a') do n = n + 1 end
    return n
end

-- Ubah teks UTF-8 dari AI menjadi teks yang aman untuk chat SA-MP (CP1251)
local UNICODE_FIX = {
    ['\226\128\152'] = "'", ['\226\128\153'] = "'",
    ['\226\128\156'] = '"', ['\226\128\157'] = '"',
    ['\226\128\166'] = '...',
    ['\226\128\147'] = '-', ['\226\128\148'] = '-',
    ['\194\160'] = ' ',
}
-- huruf beraksen Latin (U+00C0..U+00FF) -> huruf biasa, karena chat SA-MP (CP1251) tidak punya
local LATIN1 = {
    'A','A','A','A','A','A','AE','C','E','E','E','E','I','I','I','I',
    'D','N','O','O','O','O','O','x','O','U','U','U','U','Y','Th','ss',
    'a','a','a','a','a','a','ae','c','e','e','e','e','i','i','i','i',
    'd','n','o','o','o','o','o','/','o','u','u','u','u','y','th','y',
}
local function toGame(s)
    s = s:gsub('[\r\n]+', ' ')
    for k, v in pairs(UNICODE_FIX) do s = s:gsub(k, v) end
    s = s:gsub('\195([\128-\191])', function(c) return LATIN1[c:byte() - 127] end) -- ñ -> n, á -> a, dst
    s = s:gsub('\194[\161\191\176\170\186]', '') -- buang ¡ ¿ ° ª º
    s = s:gsub('[\240-\244][\128-\191][\128-\191][\128-\191]', '') -- buang emoji
    s = s:gsub('[\224-\239][\128-\191][\128-\191]', '') -- simbol lain (hati, bintang, zero-width) yang tidak bisa tampil
    s = s:gsub('[%z\1-\31\127]', '') -- karakter kontrol
    s = s:gsub('%s%s+', ' ')
    s = trim(s)
    -- buang tanda kutip pembungkus kalau AI menambahkannya
    if #s >= 2 and s:sub(1, 1) == '"' and s:sub(-1) == '"' then s = trim(s:sub(2, -2)) end
    local ok, r = pcall(u8.decode, u8, s)
    if ok and type(r) == 'string' and r ~= '' then return r end
    return (s:gsub('[\128-\255]', ''))
end

local function toUtf8(s)
    local ok, r = pcall(u8, s)
    if ok and type(r) == 'string' then return r end
    return s
end

local function myName()
    local ok, res, id = pcall(sampGetPlayerIdByCharHandle, PLAYER_PED)
    if ok and res then
        local ok2, nick = pcall(sampGetPlayerNickname, id)
        if ok2 then return nick end
    end
    return nil
end

local function isConnectedPlayer(name)
    name = name:gsub(' ', '_'):lower()
    for i = 0, 1003 do
        if sampIsPlayerConnected(i) then
            local nick = sampGetPlayerNickname(i)
            if nick and nick:lower() == name then return true end
        end
    end
    local me = myName()
    return me ~= nil and me:lower() == name
end

-- =========================================================================
-- HTTP async (effil thread + lua-requests)
-- =========================================================================
local function httpRequest(method, url, body, headerName, headerValue, cb)
    local runner = effil.thread(function(method, url, body, headerName, headerValue)
        local requests = require 'requests'
        local headers = { ['Content-Type'] = 'application/json' }
        headers[headerName] = headerValue
        local args = { headers = headers, timeout = 7 }
        if body ~= '' then args.data = body end
        local ok, res = pcall(requests.request, method, url, args)
        if not ok then return false, 0, tostring(res) end
        return true, tonumber(res.status_code) or 0, tostring(res.text or '')
    end)(method, url, body or '', headerName, headerValue)

    lua_thread.create(function()
        while true do
            local status, err = runner:status()
            if err then return cb(false, 0, 'thread error: ' .. tostring(err)) end
            if status == 'completed' then
                local ok, code, text = runner:get()
                return cb(ok, code, text)
            elseif status == 'canceled' or status == 'failed' then
                return cb(false, 0, 'thread ' .. tostring(status))
            end
            wait(0)
        end
    end)
end

local function httpPost(url, body, headerName, headerValue, cb)
    httpRequest('POST', url, body, headerName, headerValue, cb)
end

local function httpGet(url, headerName, headerValue, cb)
    httpRequest('GET', url, '', headerName, headerValue, cb)
end

local function apiErrorText(code, text)
    local ok, j = pcall(decodeJson, text)
    if ok and type(j) == 'table' then
        if type(j.error) == 'table' and j.error.message then
            return ('HTTP %d: %s'):format(code, tostring(j.error.message))
        elseif type(j.error) == 'string' then
            return ('HTTP %d: %s'):format(code, j.error)
        end
    end
    return ('HTTP %d: %s'):format(code, (text or ''):sub(1, 150))
end

-- =========================================================================
-- Provider AI
-- =========================================================================
local state = {
    blockedUntil = { gemini = 0, groq = 0 },  -- provider diistirahatkan sampai waktu ini (os.time)
    blockReason  = { gemini = '', groq = '' },
    lastProvider = '-',
    lastError = '',
    lastMs = 0,
    outQueue = {},
    inQueue = {},
    busyOut = false,
    inFlight = 0,
    recent = {},
    libs = {},
    reqTimes = {},
    stats = { skipped = 0, dropped = 0, cached = 0, batches = 0, unfocused = 0 },
}

-- notifikasi yang sama paling sering sekali per 30 detik (tidak spam chat)
local notifyTimes = {}
local function notifyThrottled(key, text)
    local now = os.time()
    if notifyTimes[key] and now - notifyTimes[key] < 30 then return end
    notifyTimes[key] = now
    pcall(notify, text)
end

-- hitung request per menit (untuk membatasi pesan masuk supaya tidak kena 429)
local function requestsLastMinute()
    local now, n, keep = os.clock(), 0, {}
    for _, t in ipairs(state.reqTimes) do
        if now - t < 60 then n = n + 1; keep[#keep + 1] = t end
    end
    state.reqTimes = keep
    return n
end
local function spendRequest() state.reqTimes[#state.reqTimes + 1] = os.clock() end

-- baca "tunggu berapa detik" dari pesan error 429 (Gemini: retryDelay, Groq: "try again in 7.5s")
local function retryAfter(resp)
    resp = tostring(resp or '')
    local s = resp:match('"retryDelay"%s*:%s*"([%d%.]+)s"')
    if s then return tonumber(s) end
    local m, sec = resp:match('try again in (%d+)m([%d%.]+)s')
    if m then return tonumber(m) * 60 + tonumber(sec) end
    s = resp:match('try again in ([%d%.]+)s')
    if s then return tonumber(s) end
    s = resp:match('try again in ([%d%.]+)ms')
    if s then return tonumber(s) / 1000 end
    return nil
end

local function callGemini(system, text, cb)
    local url = 'https://generativelanguage.googleapis.com/v1beta/models/' .. cfg.gemini_model .. ':generateContent'
    local body = encodeJson({
        systemInstruction = { parts = { { text = system } } },
        contents = { { role = 'user', parts = { { text = text } } } },
    })
    local function handle(ok, code, resp)
        if not ok then return cb(false, resp, code, resp) end
        if code ~= 200 then return cb(false, apiErrorText(code, resp), code, resp) end
        local okj, j = pcall(decodeJson, resp)
        if not okj or type(j) ~= 'table' then return cb(false, 'respon Gemini tidak valid', code) end
        local cand = j.candidates and j.candidates[1]
        local parts = cand and cand.content and cand.content.parts
        if type(parts) ~= 'table' then
            local reason = (j.promptFeedback and j.promptFeedback.blockReason) or (cand and cand.finishReason) or 'kosong'
            return cb(false, 'Gemini tidak memberi jawaban (' .. tostring(reason) .. ')', code)
        end
        local out = {}
        for _, p in ipairs(parts) do
            if p.text and not p.thought then out[#out + 1] = p.text end
        end
        local result = trim(table.concat(out, '\n'))
        if result == '' then return cb(false, 'jawaban Gemini kosong', code) end
        cb(true, result, code)
    end
    -- cara 1: key lewat header x-goog-api-key (cara resmi, juga untuk key format baru "AQ.")
    spendRequest()
    httpPost(url, body, 'x-goog-api-key', cfg.gemini_key, function(ok, code, resp)
        if ok and code == 401 and not state.geminiQueryTried then
            -- cara 2 (sekali saja per sesi): key di URL (?key=)
            state.geminiQueryTried = true
            local key = cfg.gemini_key:gsub('[^%w%-%._~]', function(c) return ('%%%02X'):format(c:byte()) end)
            spendRequest()
            return httpPost(url .. '?key=' .. key, body, 'Accept', 'application/json', handle)
        end
        handle(ok, code, resp)
    end)
end

-- dipanggil saat model Groq diganti otomatis (diisi di bagian menu)
local onGroqModelChanged = function() end

-- urutan model yang disukai; yang cepat dulu. Kalau tidak ada, ambil model chat aktif apa saja
local GROQ_PREFER = { 'openai/gpt-oss-20b', 'openai/gpt-oss-120b', 'qwen', 'llama', 'kimi', 'gemma', 'mistral' }
local GROQ_SKIP = { 'whisper', 'guard', 'tts', 'playai', 'orpheus', 'compound', 'safeguard', 'distil', 'vision', 'allam' }

local function findGroqModel(cb)
    httpGet('https://api.groq.com/openai/v1/models', 'Authorization', 'Bearer ' .. cfg.groq_key, function(ok, code, resp)
        if not ok then return cb(false, resp) end
        if code ~= 200 then return cb(false, apiErrorText(code, resp)) end
        local okj, j = pcall(decodeJson, resp)
        if not okj or type(j) ~= 'table' or type(j.data) ~= 'table' then return cb(false, 'daftar model tidak valid') end
        local list = {}
        for _, m in ipairs(j.data) do
            local id = tostring(m.id or '')
            local skip = (m.active == false) or id == ''
            for _, s in ipairs(GROQ_SKIP) do if id:lower():find(s, 1, true) then skip = true end end
            if not skip then list[#list + 1] = id end
        end
        table.sort(list)
        state.groqModels = list
        for _, want in ipairs(GROQ_PREFER) do
            for _, id in ipairs(list) do
                if id == want or id:lower():find(want, 1, true) then return cb(true, id) end
            end
        end
        if list[1] then return cb(true, list[1]) end
        cb(false, 'tidak ada model chat aktif di akun Groq ini')
    end)
end

local function callGroq(system, text, cb, retried)
    local req = {
        model = cfg.groq_model,
        messages = {
            { role = 'system', content = system },
            { role = 'user', content = text },
        },
        max_completion_tokens = 400,
    }
    -- model gpt-oss "berpikir" dulu; dibuat singkat supaya terjemahan cepat
    if cfg.groq_model:find('gpt%-oss') then
        req.reasoning_effort = 'low'
        req.max_completion_tokens = 900 -- token berpikir ikut dihitung
    end
    local body = encodeJson(req)
    spendRequest()
    httpPost('https://api.groq.com/openai/v1/chat/completions', body, 'Authorization', 'Bearer ' .. cfg.groq_key, function(ok, code, resp)
        if not ok then return cb(false, resp, code, resp) end
        -- model tidak ada / sudah dimatikan -> cari model aktif lalu coba sekali lagi
        if (code == 404 or (code == 400 and resp:find('decommission'))) and not retried then
            return findGroqModel(function(okm, model)
                if okm and model ~= cfg.groq_model then
                    cfg.groq_model = model
                    onGroqModelChanged()
                    markDirty()
                    return callGroq(system, text, cb, true)
                end
                cb(false, apiErrorText(code, resp) .. (okm and '' or (' | cari model: ' .. tostring(model))), code, resp)
            end)
        end
        if code ~= 200 then return cb(false, apiErrorText(code, resp), code, resp) end
        local okj, j = pcall(decodeJson, resp)
        if not okj or type(j) ~= 'table' then return cb(false, 'respon Groq tidak valid', code) end
        local msg = j.choices and j.choices[1] and j.choices[1].message
        local result = msg and msg.content and trim(tostring(msg.content)) or ''
        if result == '' then return cb(false, 'jawaban Groq kosong', code) end
        cb(true, result, code)
    end)
end

local function callProvider(name, system, text, cb)
    if name == 'gemini' then
        if cfg.gemini_key == '' then return cb(false, 'API key Gemini kosong', 0) end
        callGemini(system, text, cb)
    else
        if cfg.groq_key == '' then return cb(false, 'API key Groq kosong', 0) end
        callGroq(system, text, cb)
    end
end

local PROVIDER_LABEL = { gemini = 'Gemini', groq = 'Groq' }

-- istirahatkan provider yang gagal supaya pesan berikutnya tidak buang waktu
local function blockProvider(p, code, raw)
    local secs, why
    if code == 429 then
        secs = retryAfter(raw) or 60
        secs = math.max(5, math.min(secs + 1, 3600))
        why = 'kena limit (429)'
    elseif code == 401 or code == 403 then
        secs = 600
        why = 'key ditolak (' .. code .. ')'
    else
        return
    end
    state.blockedUntil[p] = os.time() + math.floor(secs)
    state.blockReason[p] = why
    notifyThrottled('block_' .. p, ('{FFAA00}%s %s, dilewati %d detik.'):format(PROVIDER_LABEL[p], why, math.floor(secs)))
end

-- Gemini dulu; kalau gagal/limit -> langsung Groq pada pesan yang sama
local function translate(system, text, cb)
    local now = os.time()
    local order = {}
    for _, p in ipairs({ 'gemini', 'groq' }) do
        if cfg[p .. '_key'] ~= '' and now >= state.blockedUntil[p] then order[#order + 1] = p end
    end
    if #order == 0 then
        if cfg.gemini_key == '' and cfg.groq_key == '' then return cb(false, 'belum ada API key (isi di /str > API)') end
        return cb(false, 'semua provider sedang istirahat (limit / key ditolak)')
    end

    local started = os.clock()
    local i, errors = 0, {}
    local function try()
        i = i + 1
        local p = order[i]
        if not p then
            state.lastError = table.concat(errors, ' | ')
            return cb(false, state.lastError)
        end
        callProvider(p, system, text, function(ok, result, code, raw)
            if ok then
                state.lastProvider = p
                state.lastMs = math.floor((os.clock() - started) * 1000)
                return cb(true, result, p)
            end
            blockProvider(p, code, raw)
            errors[#errors + 1] = p .. ': ' .. tostring(result)
            try()
        end)
    end
    try()
end

-- =========================================================================
-- Prompt
-- =========================================================================
local SAME = '__SAME__'

local function promptOut()
    local L = LANGS[cfg.out_lang]
    local p = 'Translate this SA-MP roleplay game chat message into ' .. L.name .. '. Keep the meaning and player names. '
    if L.style then
        p = p .. L.style .. ' If it is already in ' .. L.name .. ', rewrite it in that style. '
    else
        p = p .. 'Keep the casual tone and slang. If it is already in ' .. L.name .. ', return it unchanged. '
    end
    return p .. 'Reply with ONLY the result on one line: no quotes, no emojis, no notes.'
end

local function promptIn()
    local L = LANGS[cfg.in_lang]
    local p = 'Translate this SA-MP roleplay game chat message from another player into casual ' .. L.name .. '. '
        .. 'Understand street slang (American, Mexican, etc.) and translate its real meaning. Keep player names. '
        .. 'If it is already in ' .. L.name .. ' or has nothing to translate, reply exactly ' .. SAME .. '. '
    if L.style then p = p .. L.style .. ' ' end
    return p .. 'Reply with ONLY the result on one line: no quotes, no emojis, no notes.'
end

local function promptInBatch(n)
    local L = LANGS[cfg.in_lang]
    local p = 'You get ' .. n .. ' numbered SA-MP roleplay game chat lines from other players. '
        .. 'Translate each into casual ' .. L.name .. ', understanding street slang (American, Mexican, etc.). Keep player names. '
        .. 'Answer with exactly ' .. n .. ' lines in the same order, each as "<number>) <translation>". '
        .. 'If a line is already in ' .. L.name .. ' or has nothing to translate, write "<number>) ' .. SAME .. '". '
    if L.style then p = p .. L.style .. ' ' end
    return p .. 'No quotes, no emojis, no other text.'
end

-- =========================================================================
-- Kirim chat tanpa dicegat ulang
-- =========================================================================
local bypass = false
local function sendRaw(text)
    if #text > 143 then text = text:sub(1, 143) end
    bypass = true
    sampSendChat(text)
    bypass = false
end

local function safeGame(s)
    local ok, r = pcall(toGame, tostring(s))
    return ok and r or '?'
end

-- cache kecil: teks yang sama tidak diterjemahkan ulang (hemat kuota, instan)
local function newCache(max)
    local c = { data = {}, size = 0, max = max }
    function c:get(k) return self.data[k] end
    function c:set(k, v)
        if self.data[k] == nil then
            self.size = self.size + 1
            if self.size > self.max then self.data, self.size = {}, 1 end
        end
        self.data[k] = v
    end
    return c
end
local outCache = newCache(150)
local inCache = newCache(300)

-- =========================================================================
-- Antrian pesan keluar (berurutan supaya urutan chat tidak acak)
-- =========================================================================
local QUEUE_TIMEOUT = 16 -- detik; lewat dari ini pesan asli dikirim (cukup untuk Gemini + cadangan Groq)

local function processOut()
    if state.busyOut or #state.outQueue == 0 then return end
    state.busyOut = true
    local item = table.remove(state.outQueue, 1)
    local original = item.prefix .. item.text
    local cacheKey = cfg.out_lang .. '|' .. item.text
    local done = false

    -- apa pun yang terjadi, fungsi ini SELALU membuka antrian lagi
    local function finish(text, warn)
        if done then return end
        done = true
        if warn then notifyThrottled('out_warn', warn) end
        local okSend, errSend = pcall(sendRaw, text)
        if not okSend then pcall(notify, '{FF6666}Gagal kirim chat: ' .. tostring(errSend)) end
        state.busyOut = false
        processOut()
    end

    local cached = outCache:get(cacheKey)
    if cached then
        state.stats.cached = state.stats.cached + 1
        return finish(item.prefix .. cached)
    end

    -- pengaman: AI terlalu lama / tidak menjawab -> kirim pesan asli
    lua_thread.create(function()
        wait(QUEUE_TIMEOUT * 1000)
        finish(original, '{FFAA00}AI terlalu lama menjawab, pesan asli dikirim.')
    end)

    local okCall, errCall = pcall(translate, promptOut(), toUtf8(item.text), function(ok, result)
        if done then return end
        if not ok then
            return finish(original, '{FF6666}Gagal menerjemahkan, pesan asli dikirim. {AAAAAA}' .. safeGame(result):sub(1, 90))
        end
        if cfg.debug then pcall(notify, '{AAAAAA}AI: ' .. safeGame(result):sub(1, 110)) end
        local okConv, out = pcall(toGame, result)
        if not okConv then
            return finish(original, '{FF6666}Error script: ' .. tostring(out):sub(1, 90) .. ' - pesan asli dikirim.')
        end
        if countLetters(out) == 0 then
            return finish(original, '{FF6666}Jawaban AI kosong setelah dibersihkan, pesan asli dikirim.')
        end
        outCache:set(cacheKey, out)
        finish(item.prefix .. out)
    end)
    if not okCall then
        finish(original, '{FF6666}Error script: ' .. tostring(errCall):sub(1, 90) .. ' - pesan asli dikirim.')
    end
end

local function queueOut(prefix, text)
    if #state.outQueue >= 5 then
        notifyThrottled('out_full', '{FFAA00}Antrian penuh, pesan dikirim tanpa terjemahan.')
        return sendRaw(prefix .. text)
    end
    state.outQueue[#state.outQueue + 1] = { prefix = prefix, text = text }
    processOut()
end

-- =========================================================================
-- Deteksi cepat bahasa Indonesia (tanpa AI) -> tidak buang kuota & waktu
-- =========================================================================
local INDO_WORDS = {}
for w in ([[yang aku gue gua gw kamu lu lo elu dia kita kami mereka gak ga gk nggak ngga enggak engga tidak
    udah udh sudah belum blm lagi lg sini sana situ apa ini itu dan atau di ke dari buat untuk utk sama sm dong
    deh kok sih aja aj juga jg bisa bs ada tau tahu kenapa knp napa gimana gmn bagaimana dimana mana kapan siapa
    jangan jgn tolong terus trus banget bgt bang bg kak bos gan cuy cok anjir njir anjay wkwk wkwkwk awokawok
    hehe haha mantap mantul sabar bentar bntr nanti ntar mau pengen ingin kalo kalau klo karena krn soalnya
    punya mobil motor rumah polisi duit uang beli jual kerja kemana darimana ayo yuk oke makasih terima kasih]]):gmatch('%S+') do
    INDO_WORDS[w] = true
end

local function looksIndonesian(text)
    local words, hits = 0, 0
    for w in text:lower():gmatch('%a+') do
        words = words + 1
        if INDO_WORDS[w] or w:find('^wk+w') or w:find('^ha?ha') then hits = hits + 1 end
    end
    if words == 0 then return true end
    if words <= 3 then return hits >= 1 and hits * 2 >= words end
    return hits >= 2 and hits / words >= 0.25
end

-- =========================================================================
-- Antrian pesan masuk: digabung (batch) + paralel supaya tidak menumpuk
-- =========================================================================
local IN_PARALLEL = 2   -- maksimal request pesan masuk yang berjalan bersamaan
local IN_BATCH    = 6   -- maksimal pesan digabung dalam satu request
local IN_MAX_AGE  = 25  -- detik; pesan yang menunggu lebih lama dari ini dibuang

local function showIn(name, gameText)
    pcall(function()
        sampAddChatMessage(('{66CCFF}[STR] {FFFF99}%s{FFFFFF}: %s'):format(name, gameText), -1)
    end)
end

local function handleInResult(item, result)
    local ck = cfg.in_lang .. '|' .. item.text
    result = trim(tostring(result or ''))
    if result == '' then return end
    if result:find(SAME, 1, true) then
        inCache:set(ck, SAME)
        return
    end
    local okConv, g = pcall(toGame, result)
    if not okConv or countLetters(g) == 0 then return end
    -- jawaban sama persis dengan aslinya = tidak perlu ditampilkan
    if g:lower() == item.text:lower() then
        inCache:set(ck, SAME)
        return
    end
    inCache:set(ck, g)
    showIn(item.name, g)
end

local processIn

local function runInBatch(batch)
    state.inFlight = state.inFlight + 1
    state.stats.batches = state.stats.batches + 1
    local done = false
    local function finish()
        if done then return end
        done = true
        state.inFlight = state.inFlight - 1
        processIn()
    end
    lua_thread.create(function()
        wait(QUEUE_TIMEOUT * 1000)
        finish()
    end)

    local system, text
    if #batch == 1 then
        system, text = promptIn(), toUtf8(batch[1].text)
    else
        local lines = {}
        for i, it in ipairs(batch) do
            lines[i] = i .. ') ' .. (toUtf8(it.text):gsub('[\r\n]+', ' '))
        end
        system, text = promptInBatch(#batch), table.concat(lines, '\n')
    end

    local okCall = pcall(translate, system, text, function(ok, result)
        if done then return end
        if ok then
            if cfg.debug then pcall(notify, '{AAAAAA}AI (masuk x' .. #batch .. '): ' .. safeGame(result):sub(1, 110)) end
            if #batch == 1 then
                handleInResult(batch[1], (tostring(result):gsub('^%s*1%s*[%)%.:]%s*', '')))
            else
                local got = {}
                for line in (tostring(result) .. '\n'):gmatch('([^\r\n]*)\r?\n') do
                    local n, t = line:match('^%s*(%d+)%s*[%)%.:%-]%s*(.*)$')
                    n = tonumber(n)
                    if n and batch[n] and not got[n] then
                        got[n] = true
                        handleInResult(batch[n], t)
                    end
                end
            end
        elseif cfg.debug then
            pcall(notify, '{AAAAAA}Gagal terjemah pesan masuk: ' .. safeGame(result):sub(1, 90))
        end
        finish()
    end)
    if not okCall then finish() end
end

processIn = function()
    while state.inFlight < IN_PARALLEL and #state.inQueue > 0 do
        -- buang pesan yang sudah terlalu lama menunggu (tidak relevan lagi)
        local now = os.clock()
        while state.inQueue[1] and now - state.inQueue[1].t > IN_MAX_AGE do
            table.remove(state.inQueue, 1)
            state.stats.dropped = state.stats.dropped + 1
        end
        if #state.inQueue == 0 then return end
        -- batas request per menit; sisa antrian dicoba lagi dari loop utama
        if requestsLastMinute() >= cfg.max_rpm then return end
        local batch = {}
        while #batch < IN_BATCH and #state.inQueue > 0 do
            batch[#batch + 1] = table.remove(state.inQueue, 1)
        end
        runInBatch(batch)
    end
end

-- =========================================================================
-- Mode fokus: di tempat ramai, hanya terjemahkan pemain tertentu
--   * daftar manual  : /str add ID  (tersimpan di config, pakai nickname)
--   * otomatis       : pemain di dekatmu saat kamu chat, pemain yang kamu
--                      bidik/target, dan tujuan /pm /w  (berlaku beberapa menit)
-- =========================================================================
local focusAuto = {} -- nickname (huruf kecil) -> { nick = asli, expire = os.time, why = alasan }
local FOCUS_PM_CMDS = { pm = true, w = true, whisper = true, sms = true }

local function normName(n)
    return (tostring(n or ''):gsub(' ', '_'):lower())
end

local function focusManualList()
    local list = {}
    for n in cfg.focus_names:gmatch('[^,%s]+') do list[#list + 1] = n end
    return list
end

local function isFocused(name)
    local n = normName(name)
    for _, m in ipairs(focusManualList()) do
        if m:lower() == n then return true end
    end
    local a = focusAuto[n]
    return a ~= nil and a.expire > os.time()
end

local function focusAdd(nick)
    for _, m in ipairs(focusManualList()) do
        if m:lower() == nick:lower() then return false end
    end
    local list = focusManualList()
    list[#list + 1] = nick
    cfg.focus_names = table.concat(list, ',')
    markDirty()
    return true
end

local function focusRemove(nick)
    local list, removed = {}, false
    for _, m in ipairs(focusManualList()) do
        if m:lower() == nick:lower() then removed = true else list[#list + 1] = m end
    end
    if focusAuto[nick:lower()] then focusAuto[nick:lower()] = nil; removed = true end
    cfg.focus_names = table.concat(list, ',')
    markDirty()
    return removed
end

local function focusAutoAdd(nick, why)
    if not nick or nick == '' then return end
    local n = nick:lower()
    local wasActive = focusAuto[n] and focusAuto[n].expire > os.time()
    focusAuto[n] = { nick = nick, expire = os.time() + cfg.focus_auto_min * 60, why = why }
    if not wasActive and cfg.focus_mode and cfg.focus_notify then
        notifyThrottled('fa_' .. n, ('{AAAAAA}Fokus otomatis: %s (%s)'):format(nick, why))
    end
end

-- cari pemain dari ID atau sebagian nama
local function findPlayer(arg)
    arg = trim(arg or '')
    if arg == '' then return nil, 'isi ID atau nama' end
    local id = tonumber(arg)
    if id then
        if sampIsPlayerConnected(id) then return sampGetPlayerNickname(id), id end
        return nil, 'ID ' .. id .. ' tidak online'
    end
    local q, found = arg:lower(), nil
    for i = 0, 1003 do
        if sampIsPlayerConnected(i) then
            local nick = sampGetPlayerNickname(i)
            if nick and nick:lower():find(q, 1, true) then
                if found then return nil, 'nama "' .. arg .. '" cocok dengan lebih dari satu pemain, pakai ID' end
                found = { nick, i }
            end
        end
    end
    if found then return found[1], found[2] end
    return nil, 'pemain "' .. arg .. '" tidak ditemukan'
end

local function playersNear(radius)
    local res = {}
    local ok, x, y, z = pcall(getCharCoordinates, PLAYER_PED)
    if not ok then return res end
    for i = 0, 1003 do
        if sampIsPlayerConnected(i) then
            local okh, has, ped = pcall(sampGetCharHandleBySampPlayerId, i)
            if okh and has and doesCharExist(ped) then
                local px, py, pz = getCharCoordinates(ped)
                if getDistanceBetweenCoords3d(x, y, z, px, py, pz) <= radius then
                    res[#res + 1] = sampGetPlayerNickname(i)
                end
            end
        end
    end
    return res
end

local function autoFocusTalk()
    if not cfg.focus_auto_talk then return end
    for _, nick in ipairs(playersNear(cfg.focus_radius)) do
        focusAutoAdd(nick, 'dekat saat kamu chat')
    end
end

local function autoFocusTarget()
    if not cfg.focus_auto_target then return end
    local ok, res, ped = pcall(getCharPlayerIsTargeting, PLAYER_HANDLE)
    if not ok or not res then return end
    local ok2, has, id = pcall(sampGetPlayerIdByCharHandle, ped)
    if ok2 and has then focusAutoAdd(sampGetPlayerNickname(id), 'kamu bidik') end
end

local function focusCount()
    local n = #focusManualList()
    local now = os.time()
    for _, a in pairs(focusAuto) do if a.expire > now then n = n + 1 end end
    return n
end

local function queueIn(name, text)
    text = trim(text)
    if countLetters(text) < cfg.min_letters then return end
    if cfg.focus_mode and not isFocused(name) then
        state.stats.unfocused = state.stats.unfocused + 1
        return
    end
    if cfg.skip_indo and LANGS[cfg.in_lang].name == 'Indonesian' and looksIndonesian(text) then
        state.stats.skipped = state.stats.skipped + 1
        return
    end
    local cached = inCache:get(cfg.in_lang .. '|' .. text)
    if cached then
        state.stats.cached = state.stats.cached + 1
        if cached ~= SAME then showIn(name, cached) end
        return
    end
    local key = name .. '|' .. text
    local now = os.clock()
    if state.recent[key] and now - state.recent[key] < 3 then return end
    state.recent[key] = now
    if #state.inQueue >= 20 then
        table.remove(state.inQueue, 1)
        state.stats.dropped = state.stats.dropped + 1
    end
    state.inQueue[#state.inQueue + 1] = { name = name, text = text, t = now }
    processIn()
end

-- =========================================================================
-- Hook SA-MP
-- =========================================================================
function sampev.onSendChat(msg)
    if bypass or not cfg.enabled then return end
    if cfg.focus_mode then pcall(autoFocusTalk) end
    if not cfg.translate_out then return end
    local p = cfg.raw_prefix
    if p ~= '' and msg:sub(1, #p) == p then
        local rest = trim(msg:sub(#p + 1))
        if rest == '' then return false end
        return { rest } -- kirim apa adanya tanpa diterjemahkan
    end
    if countLetters(msg) < 1 then return end
    queueOut('', msg)
    return false
end

local function cmdAllowed(cmd)
    for c in cfg.cmd_list:gmatch('[^,%s]+') do
        if c:lower() == cmd:lower() then return true end
    end
    return false
end

function sampev.onSendCommand(command)
    if bypass or not cfg.enabled then return end
    -- /pm ID pesan, /w ID pesan -> pemain tujuan otomatis difokuskan
    local pc, pid = command:match('^/(%S+)%s+(%d+)')
    if pc and FOCUS_PM_CMDS[pc:lower()] and sampIsPlayerConnected(tonumber(pid)) then
        focusAutoAdd(sampGetPlayerNickname(tonumber(pid)), '/' .. pc:lower())
    end
    if not cfg.translate_out or not cfg.translate_cmds then return end
    local cmd, rest = command:match('^/(%S+)%s+(.+)$')
    if not cmd or not cmdAllowed(cmd) then return end
    if countLetters(rest) < 1 then return end
    queueOut('/' .. cmd .. ' ', rest)
    return false
end

function sampev.onChatMessage(playerId, text)
    if not cfg.enabled or not cfg.translate_in then return end
    local ok, name = pcall(sampGetPlayerNickname, playerId)
    queueIn(ok and name or ('ID ' .. playerId), text)
end

local CHAT_PATTERNS = {
    '^(.-) says %b(): (.+)$',
    '^(.-) says: (.+)$',
    '^(.-) shouts: (.+)$',
    '^(.-) whispers: (.+)$',
    '^(.-) %(phone%): (.+)$',
    '^%(%(%s*(.-): (.-)%s*%)%)$',
    '^(.-)%s*%[%d+%]: (.+)$',
    '^(.-)%s*%(%d+%): (.+)$',
    '^(.-): (.+)$',
    '^%*%s*(.-)%s+(.+)$',     -- /me : "* Nama melakukan sesuatu"
}

function sampev.onServerMessage(color, text)
    if not cfg.enabled or not cfg.translate_in or not cfg.translate_server then return end
    local clean = text:gsub('{%x%x%x%x%x%x}', '')
    for _, pat in ipairs(CHAT_PATTERNS) do
        local name, msg = clean:match(pat)
        if name then
            name = trim(name:gsub('^%[.-%]%s*', '')) -- buang tag seperti [Admin]
            if name ~= '' and #name <= 24 and isConnectedPlayer(name) then
                local me = myName()
                if not (me and me:lower() == name:gsub(' ', '_'):lower()) then
                    queueIn(name, msg)
                end
            end
            return
        end
    end
end

-- =========================================================================
-- Menu ImGui (mimgui)
-- =========================================================================
local ui = {
    show            = new.bool(false),
    enabled         = new.bool(cfg.enabled),
    translate_out   = new.bool(cfg.translate_out),
    translate_in    = new.bool(cfg.translate_in),
    translate_server= new.bool(cfg.translate_server),
    translate_cmds  = new.bool(cfg.translate_cmds),
    debug           = new.bool(cfg.debug),
    out_lang        = new.int(cfg.out_lang - 1),
    in_lang         = new.int(cfg.in_lang - 1),
    min_letters     = new.int(cfg.min_letters),
    max_rpm         = new.int(cfg.max_rpm),
    skip_indo       = new.bool(cfg.skip_indo),
    focus_mode      = new.bool(cfg.focus_mode),
    focus_auto_talk = new.bool(cfg.focus_auto_talk),
    focus_auto_target = new.bool(cfg.focus_auto_target),
    focus_notify    = new.bool(cfg.focus_notify),
    focus_radius    = new.int(cfg.focus_radius),
    focus_auto_min  = new.int(cfg.focus_auto_min),
    focus_input     = new.char[32](''),
    raw_prefix      = new.char[8](cfg.raw_prefix),
    cmd_list        = new.char[128](cfg.cmd_list),
    gemini_key      = new.char[256](cfg.gemini_key),
    gemini_model    = new.char[96](cfg.gemini_model),
    groq_key        = new.char[256](cfg.groq_key),
    groq_model      = new.char[96](cfg.groq_model),
    show_keys       = new.bool(false),
    test_text       = new.char[256]('di sana ada polisi'),
    test_in_text    = new.char[256]("Just relax, there's only one police officer there"),
    test_log        = {},
}
local langItems = new['const char*'][#langLabels](langLabels)

onGroqModelChanged = function()
    ffi.copy(ui.groq_model, cfg.groq_model:sub(1, sizeof(ui.groq_model) - 1))
end

local function syncUiFromCfg()
    ui.enabled[0] = cfg.enabled
    ui.focus_mode[0] = cfg.focus_mode
end

local function testLog(line)
    table.insert(ui.test_log, 1, os.date('[%H:%M:%S] ') .. line)
    while #ui.test_log > 30 do table.remove(ui.test_log) end
end

local function wrapped(text)
    imgui.PushTextWrapPos(0)
    imgui.TextUnformatted(text)
    imgui.PopTextWrapPos()
end

local function colored(r, g, b, text)
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(r, g, b, 1))
    imgui.TextUnformatted(text)
    imgui.PopStyleColor()
end

local function runTest(label, fn)
    local started = os.clock()
    testLog(label .. ' ... menunggu')
    fn(function(ok, result, provider)
        local ms = math.floor((os.clock() - started) * 1000)
        if ok then
            testLog(('%s OK (%s, %d ms): %s'):format(label, provider or '-', ms, result))
        else
            testLog(('%s GAGAL (%d ms): %s'):format(label, ms, tostring(result)))
        end
    end)
end

local function checkbox(label, key)
    if imgui.Checkbox(label, ui[key]) then
        cfg[key] = ui[key][0]
        markDirty()
    end
end

local function inputText(label, key, flags)
    if imgui.InputText(label, ui[key], sizeof(ui[key]), flags or 0) then
        local v = ffistr(ui[key])
        if key:find('_key$') then v = v:gsub('%s', '') end -- buang spasi/enter yang ikut tercopy
        cfg[key] = v
        markDirty()
    end
end

-- info singkat agar mudah cek key tanpa menampilkan isinya
local function keyInfo(key, expectPrefix)
    local k = cfg[key]
    if k == '' then
        colored(1, 0.6, 0.3, '  Key kosong')
        return
    end
    local info = ('  %d karakter, awalan "%s..."'):format(#k, k:sub(1, 4))
    local okPrefix = not expectPrefix
    for p in (expectPrefix or ''):gmatch('[^|]+') do
        if k:sub(1, #p) == p then okPrefix = true end
    end
    if not okPrefix then
        colored(1, 0.6, 0.3, info .. '  -> biasanya diawali ' .. expectPrefix:gsub('|', ' / '))
    else
        colored(0.6, 0.9, 0.6, info)
    end
end

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
end)

imgui.OnFrame(function() return ui.show[0] end, function()
    imgui.SetNextWindowSize(imgui.ImVec2(560, 500), imgui.Cond.FirstUseEver)
    imgui.Begin('STR Translator  (Gemini -> Groq)', ui.show)

    -- status singkat
    if cfg.enabled then colored(0.4, 1, 0.4, 'Status: AKTIF') else colored(1, 0.4, 0.4, 'Status: MATI') end
    imgui.SameLine()
    imgui.TextUnformatted(('  |  Terakhir: %s (%d ms)  |  Antrian masuk: %d'):format(state.lastProvider, state.lastMs, #state.inQueue))
    if cfg.focus_mode then
        colored(0.5, 0.8, 1, ('Mode fokus ON: hanya %d pemain yang diterjemahkan  (/str list)'):format(focusCount()))
    end
    for _, p in ipairs({ 'gemini', 'groq' }) do
        local left = state.blockedUntil[p] - os.time()
        if left > 0 then
            colored(1, 0.8, 0.3, ('%s dilewati %d detik lagi: %s'):format(PROVIDER_LABEL[p], left, state.blockReason[p]))
            imgui.SameLine()
            if imgui.SmallButton('Coba lagi##' .. p) then state.blockedUntil[p] = 0 end
        end
    end
    imgui.Separator()

    if imgui.BeginTabBar('str_tabs') then
        -- ---------------------------------------------------------------- Umum
        if imgui.BeginTabItem('Umum') then
            checkbox('Penerjemah aktif', 'enabled')
            imgui.Spacing()
            checkbox('Terjemahkan pesan yang aku ketik', 'translate_out')
            imgui.SetNextItemWidth(200)
            if imgui.Combo('Bahasa pesanku', ui.out_lang, langItems, #langLabels) then
                cfg.out_lang = ui.out_lang[0] + 1
                markDirty()
            end
            imgui.Spacing()
            checkbox('Terjemahkan pesan lawan bicara', 'translate_in')
            imgui.SetNextItemWidth(200)
            if imgui.Combo('Bahasa terjemahan lawan', ui.in_lang, langItems, #langLabels) then
                cfg.in_lang = ui.in_lang[0] + 1
                markDirty()
            end
            checkbox('Baca chat dari pesan server (format "Nama says: ...")', 'translate_server')
            imgui.SetNextItemWidth(120)
            if imgui.InputInt('Minimal huruf pesan lawan', ui.min_letters) then
                if ui.min_letters[0] < 1 then ui.min_letters[0] = 1 end
                cfg.min_letters = ui.min_letters[0]
                markDirty()
            end
            checkbox('Lewati pesan lawan yang sudah bahasa Indonesia (tanpa AI, lebih cepat)', 'skip_indo')
            imgui.SetNextItemWidth(120)
            if imgui.InputInt('Batas request/menit untuk pesan lawan', ui.max_rpm) then
                if ui.max_rpm[0] < 1 then ui.max_rpm[0] = 1 end
                cfg.max_rpm = ui.max_rpm[0]
                markDirty()
            end
            wrapped(('Dilewati (sudah Indonesia): %d  |  Bukan fokus: %d  |  Dari cache: %d  |  Dibuang (kelamaan): %d  |  Request: %d'):format(
                state.stats.skipped, state.stats.unfocused, state.stats.cached, state.stats.dropped, state.stats.batches))
            imgui.Separator()
            imgui.SetNextItemWidth(60)
            inputText('Awalan kirim tanpa terjemah', 'raw_prefix')
            wrapped('Contoh: ketik ".halo" -> terkirim "halo" tanpa diterjemahkan.')
            imgui.Spacing()
            checkbox('Mode debug (tampilkan jawaban AI di chat)', 'debug')
            imgui.Spacing()
            checkbox('Terjemahkan juga perintah ini:', 'translate_cmds')
            imgui.SetNextItemWidth(250)
            inputText('##cmdlist', 'cmd_list')
            wrapped('Pisahkan dengan koma, tanpa garis miring. Contoh: b,s,low,me,do')
            imgui.EndTabItem()
        end

        -- ---------------------------------------------------------------- API
        if imgui.BeginTabItem('API') then
            local keyFlags = ui.show_keys[0] and 0 or imgui.InputTextFlags.Password
            colored(0.5, 0.8, 1, 'Gemini (utama)')
            imgui.SetNextItemWidth(380)
            inputText('API key Gemini', 'gemini_key', keyFlags)
            keyInfo('gemini_key', 'AIza|AQ.')
            imgui.SetNextItemWidth(250)
            inputText('Model Gemini', 'gemini_model')
            imgui.Spacing()
            colored(0.5, 0.8, 1, 'Groq (cadangan saat Gemini habis/gagal)')
            imgui.SetNextItemWidth(380)
            inputText('API key Groq', 'groq_key', keyFlags)
            keyInfo('groq_key', 'gsk_')
            imgui.SetNextItemWidth(250)
            inputText('Model Groq', 'groq_model')
            if imgui.Button('Cari model Groq otomatis') then
                if cfg.groq_key == '' then
                    state.groqFind = 'Isi API key Groq dulu.'
                else
                    state.groqFind = 'Mencari...'
                    findGroqModel(function(ok, model)
                        if ok then
                            cfg.groq_model = model
                            onGroqModelChanged()
                            markDirty()
                            state.groqFind = 'Dipakai: ' .. model
                        else
                            state.groqFind = 'Gagal: ' .. tostring(model)
                        end
                    end)
                end
            end
            if state.groqFind then
                imgui.SameLine()
                imgui.TextUnformatted(state.groqFind)
            end
            if state.groqModels and #state.groqModels > 0 then
                wrapped('Model aktif di akunmu: ' .. table.concat(state.groqModels, ', '))
            end
            imgui.Spacing()
            imgui.Checkbox('Tampilkan API key', ui.show_keys)
            imgui.Separator()
            wrapped('Kena limit (429): provider dilewati sesuai waktu tunggu dari server. Key ditolak (401/403): dilewati 10 menit. Pesan tetap jalan lewat provider lain.')
            wrapped('Key disimpan di moonloader/config/str_translator.json (teks biasa). Jangan bagikan file itu.')
            imgui.EndTabItem()
        end

        -- ---------------------------------------------------------------- Fokus
        if imgui.BeginTabItem('Fokus') then
            checkbox('Mode fokus (hanya terjemahkan pemain di daftar fokus)', 'focus_mode')
            wrapped('Cocok di tempat ramai: pesan orang lain diabaikan, kuota API jauh lebih awet. Pesanmu sendiri tetap diterjemahkan.')
            imgui.Separator()
            colored(0.5, 0.8, 1, 'Fokus otomatis')
            checkbox('Pemain di dekatku saat aku chat', 'focus_auto_talk')
            imgui.SameLine()
            imgui.SetNextItemWidth(90)
            if imgui.InputInt('meter##radius', ui.focus_radius) then
                if ui.focus_radius[0] < 1 then ui.focus_radius[0] = 1 end
                cfg.focus_radius = ui.focus_radius[0]
                markDirty()
            end
            checkbox('Pemain yang aku bidik / target', 'focus_auto_target')
            imgui.TextUnformatted('Tujuan /pm dan /w juga otomatis difokuskan.')
            imgui.SetNextItemWidth(90)
            if imgui.InputInt('menit fokus otomatis berlaku', ui.focus_auto_min) then
                if ui.focus_auto_min[0] < 1 then ui.focus_auto_min[0] = 1 end
                cfg.focus_auto_min = ui.focus_auto_min[0]
                markDirty()
            end
            checkbox('Kabari di chat saat ada fokus otomatis baru', 'focus_notify')
            imgui.Separator()

            colored(0.5, 0.8, 1, 'Daftar fokus manual (tersimpan)')
            imgui.SetNextItemWidth(160)
            imgui.InputText('##focusadd', ui.focus_input, sizeof(ui.focus_input))
            imgui.SameLine()
            if imgui.Button('Tambah (ID / nama)') then
                local nick, err = findPlayer(ffistr(ui.focus_input))
                if nick then
                    focusAdd(nick)
                    state.focusMsg = 'Ditambah: ' .. nick
                    ffi.copy(ui.focus_input, '')
                else
                    state.focusMsg = err
                end
            end
            if state.focusMsg then imgui.SameLine(); imgui.TextUnformatted(state.focusMsg) end
            local manual = focusManualList()
            if #manual == 0 then imgui.TextUnformatted('  (kosong)') end
            for i, nick in ipairs(manual) do
                if imgui.SmallButton('x##m' .. i) then focusRemove(nick) end
                imgui.SameLine()
                imgui.TextUnformatted(nick)
            end
            imgui.Spacing()
            colored(0.5, 0.8, 1, 'Fokus otomatis aktif')
            local now, any = os.time(), false
            for key, a in pairs(focusAuto) do
                if a.expire > now then
                    any = true
                    if imgui.SmallButton('x##a' .. key) then focusAuto[key] = nil end
                    imgui.SameLine()
                    imgui.TextUnformatted(('%s  -  %s, sisa %d detik'):format(a.nick, a.why, a.expire - now))
                end
            end
            if not any then imgui.TextUnformatted('  (belum ada)') end
            imgui.Separator()
            wrapped('Perintah: /str fokus (on/off), /str add ID, /str del ID, /str list, /str clear')
            imgui.EndTabItem()
        end

        -- ---------------------------------------------------------------- Test
        if imgui.BeginTabItem('Test') then
            colored(0.5, 0.8, 1, 'Cek library')
            for _, name in ipairs({ 'effil', 'requests', 'ssl', 'mimgui', 'encoding' }) do
                local ok = state.libs[name]
                if ok then colored(0.4, 1, 0.4, '  [OK] ' .. name) else colored(1, 0.4, 0.4, '  [TIDAK ADA] ' .. name) end
            end
            imgui.Separator()

            imgui.SetNextItemWidth(380)
            imgui.InputText('Teks pesanku', ui.test_text, sizeof(ui.test_text))
            if imgui.Button('Test Gemini') then
                local t = ffistr(ui.test_text)
                runTest('Gemini', function(done)
                    callProvider('gemini', promptOut(), t, function(ok, r) done(ok, r, 'gemini') end)
                end)
            end
            imgui.SameLine()
            if imgui.Button('Test Groq') then
                local t = ffistr(ui.test_text)
                runTest('Groq (' .. cfg.groq_model .. ')', function(done)
                    callProvider('groq', promptOut(), t, function(ok, r) done(ok, r, 'groq') end)
                end)
            end
            imgui.SameLine()
            if imgui.Button('Test otomatis (Gemini -> Groq)') then
                local t = ffistr(ui.test_text)
                runTest('Keluar -> ' .. LANGS[cfg.out_lang].label, function(done) translate(promptOut(), t, done) end)
            end

            imgui.Spacing()
            imgui.SetNextItemWidth(380)
            imgui.InputText('Pesan lawan', ui.test_in_text, sizeof(ui.test_in_text))
            if imgui.Button('Simulasi pesan masuk (muncul di chat)') then
                local t = ffistr(ui.test_in_text)
                runTest('Masuk -> ' .. LANGS[cfg.in_lang].label, function(done)
                    translate(promptIn(), t, function(ok, r, p)
                        if ok and not r:find(SAME, 1, true) then
                            sampAddChatMessage('{66CCFF}[STR] {FFFF99}Test{FFFFFF}: ' .. toGame(r), -1)
                        elseif ok then
                            r = '(sudah ' .. LANGS[cfg.in_lang].label .. ', tidak diterjemahkan)'
                        end
                        done(ok, r, p)
                    end)
                end)
            end
            imgui.SameLine()
            if imgui.Button('Bersihkan log') then ui.test_log = {} end

            imgui.Separator()
            if state.lastError ~= '' then
                colored(1, 0.5, 0.5, 'Error terakhir:')
                wrapped(state.lastError)
                imgui.Separator()
            end
            imgui.BeginChild('testlog', imgui.ImVec2(0, 0), true)
            for _, line in ipairs(ui.test_log) do wrapped(line) end
            imgui.EndChild()
            imgui.EndTabItem()
        end
        imgui.EndTabBar()
    end
    imgui.End()
end)

-- =========================================================================
-- Main
-- =========================================================================
function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end

    loadCfg()
    ui.enabled[0]          = cfg.enabled
    ui.translate_out[0]    = cfg.translate_out
    ui.translate_in[0]     = cfg.translate_in
    ui.translate_server[0] = cfg.translate_server
    ui.translate_cmds[0]   = cfg.translate_cmds
    ui.debug[0]            = cfg.debug
    ui.out_lang[0]         = cfg.out_lang - 1
    ui.in_lang[0]          = cfg.in_lang - 1
    ui.min_letters[0]      = cfg.min_letters
    ui.max_rpm[0]          = cfg.max_rpm
    ui.skip_indo[0]        = cfg.skip_indo
    ui.focus_mode[0]       = cfg.focus_mode
    ui.focus_auto_talk[0]  = cfg.focus_auto_talk
    ui.focus_auto_target[0]= cfg.focus_auto_target
    ui.focus_notify[0]     = cfg.focus_notify
    ui.focus_radius[0]     = cfg.focus_radius
    ui.focus_auto_min[0]   = cfg.focus_auto_min
    for _, k in ipairs({ 'raw_prefix', 'cmd_list', 'gemini_key', 'gemini_model', 'groq_key', 'groq_model' }) do
        ffi.copy(ui[k], cfg[k]:sub(1, sizeof(ui[k]) - 1))
    end

    for _, name in ipairs({ 'effil', 'requests', 'ssl', 'mimgui', 'encoding' }) do
        state.libs[name] = (pcall(require, name))
    end

    sampRegisterChatCommand('str', function(arg)
        arg = trim((arg or ''):lower())
        if arg == 'on' then
            cfg.enabled = true
            syncUiFromCfg()
            markDirty()
            notify('Penerjemah {66FF66}AKTIF{FFFFFF}. Pesanku -> ' .. LANGS[cfg.out_lang].label
                .. ', pesan lawan -> ' .. LANGS[cfg.in_lang].label)
        elseif arg == 'off' or arg == 'of' then
            cfg.enabled = false
            syncUiFromCfg()
            markDirty()
            notify('Penerjemah {FF6666}MATI{FFFFFF}.')
        elseif arg:match('^fokus') or arg:match('^focus') then
            local v = arg:match('^%a+%s+(%a+)$')
            if v == 'on' then cfg.focus_mode = true
            elseif v == 'off' or v == 'of' then cfg.focus_mode = false
            else cfg.focus_mode = not cfg.focus_mode end
            syncUiFromCfg()
            markDirty()
            notify('Mode fokus ' .. (cfg.focus_mode and '{66FF66}ON' or '{FF6666}OFF') .. '{FFFFFF}. '
                .. (cfg.focus_mode and ('Pesan lawan hanya diterjemahkan dari %d pemain yang difokuskan.'):format(focusCount()) or 'Semua pesan lawan diterjemahkan.'))
        elseif arg:match('^add%s') or arg:match('^del%s') then
            local action, who = arg:match('^(%a+)%s+(.+)$')
            local nick, err = findPlayer(who)
            if not nick then return notify('{FF6666}' .. err) end
            if action == 'add' then
                if focusAdd(nick) then notify('Fokus ditambah: {FFFF99}' .. nick) else notify(nick .. ' sudah ada di daftar fokus.') end
                if not cfg.focus_mode then notify('Mode fokus masih OFF. Ketik {FFFF99}/str fokus{FFFFFF} untuk menyalakan.') end
            else
                if focusRemove(nick) then notify('Fokus dihapus: ' .. nick) else notify(nick .. ' tidak ada di daftar fokus.') end
            end
        elseif arg == 'list' then
            local names = focusManualList()
            local now, autos = os.time(), {}
            for _, a in pairs(focusAuto) do
                if a.expire > now then autos[#autos + 1] = ('%s (%dm)'):format(a.nick, math.ceil((a.expire - now) / 60)) end
            end
            notify(('Mode fokus %s. Manual: %s'):format(cfg.focus_mode and 'ON' or 'OFF', #names > 0 and table.concat(names, ', ') or '-'))
            notify('Otomatis: ' .. (#autos > 0 and table.concat(autos, ', ') or '-'))
        elseif arg == 'clear' then
            cfg.focus_names = ''
            focusAuto = {}
            markDirty()
            notify('Daftar fokus dikosongkan.')
        else
            ui.show[0] = not ui.show[0]
        end
    end)

    notify('Loaded v1.4. Ketik {FFFF99}/str{FFFFFF} untuk menu, {FFFF99}/str on{FFFFFF} / {FFFF99}/str off{FFFFFF}. CopyRight By:Bobwan.')
    if not state.libs.requests or not state.libs.ssl or not state.libs.effil then
        notify('{FF6666}Library kurang (effil / requests / ssl). Cek tab Test di /str.')
    end
    if cfg.gemini_key == '' and cfg.groq_key == '' then
        notify('Belum ada API key. Isi dulu di {FFFF99}/str{FFFFFF} > tab API.')
    end

    markDirty() -- simpan config (termasuk hasil migrasi versi lama)
    local tick = 0
    while true do
        wait(250)
        -- lanjutkan antrian pesan masuk yang tertahan batas request/menit
        if #state.inQueue > 0 then pcall(processIn) end
        if cfg.enabled and cfg.focus_mode then pcall(autoFocusTarget) end
        tick = tick + 1
        if tick % 4 == 0 then
            if dirty then
                dirty = false
                saveCfg()
            end
            -- bersihkan cache anti-duplikat
            local now = os.clock()
            for k, t in pairs(state.recent) do
                if now - t > 10 then state.recent[k] = nil end
            end
        end
    end
end
