local semaphore = require("ngx.semaphore")
local loop = require("kong.timer.loop")
local utils = require("kong.timer.utils")
local constants = require("kong.timer.constants")

local ngx_now = ngx.now
local ngx_sleep = ngx.sleep
local ngx_update_time = ngx.update_time

local math_abs = math.abs
local math_max = math.max
local math_min = math.min

local setmetatable = setmetatable

local _M = {}

local meta_table = {
    __index = _M,
}


local function thread_init(self)
    local timer_sys = self.timer_sys
    local wheels = timer_sys.wheels
    local opt_resolution = timer_sys.opt.resolution

    ngx_sleep(opt_resolution)

    ngx_update_time()
    wheels.real_time = ngx_now()
    wheels.expected_time = wheels.real_time - opt_resolution

    return loop.ACTION_CONTINUE
end


local function thread_body(self)
    local timer_sys = self.timer_sys
    local wheels = timer_sys.wheels

    if timer_sys.enable then
        -- update the status of the wheel group
        wheels:sync_time()

        if not utils.table_is_empty(wheels.ready_jobs) then
            self.wake_up_mover_thread()
        end
    end

    return loop.ACTION_CONTINUE
end


local function thread_after(self)
    local timer_sys = self.timer_sys
    local wheels = timer_sys.wheels

    local closest = wheels:get_closest()

    closest = math_max(closest, timer_sys.opt.resolution)
    closest = math_min(closest,
                       constants.TOLERANCE_OF_GRACEFUL_SHUTDOWN)

    local ok, err = self.wake_up_semaphore:wait(closest)
    return loop.ACTION_CONTINUE
end


function _M:set_wake_up_mover_thread_callback(callback)
    self.wake_up_mover_thread = callback
end


function _M:kill()
    self.thread:kill()
end


function _M:wake_up()
    local wake_up_semaphore = self.wake_up_semaphore
    local count = wake_up_semaphore:count()

    if count <= 0 then
        wake_up_semaphore:post(math_abs(count) + 1)
    end
end


function _M:spawn()
    self.thread:spawn()
end


function _M.new(timer_sys)
    local self = {
        timer_sys = timer_sys,
        wake_up_semaphore = semaphore.new(0),
    }

    self.thread = loop.new({
        init = {
            argc = 1,
            argv = {
                self,
            },
            callback = thread_init,
        },

        loop_body = {
            argc = 1,
            argv = {
                self,
            },
            callback = thread_body,
        },

        after = {
            argc = 1,
            argv = {
                self,
            },
            callback = thread_after,
        },
    })

    return setmetatable(self, meta_table)
end


return _M