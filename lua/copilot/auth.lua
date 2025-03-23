local api = require("copilot.api")
local c = require("copilot.client")
local logger = require("copilot.logger")

local M = {}

local function echo(message)
  vim.cmd('echom "[Copilot] ' .. tostring(message):gsub('"', '\\"') .. '"')
end

-- Write hosts.json file with auth information
local function write_hosts_json(token, user)
  local config_path = M.find_config_path()
  if not config_path then
    logger.error("Could not find config path")
    return false
  end

  -- Make sure github-copilot directory exists
  local github_copilot_dir = config_path .. "/github-copilot"
  if vim.fn.isdirectory(github_copilot_dir) == 0 then
    vim.fn.mkdir(github_copilot_dir, "p")
  end

  local hosts_data = {
    ["github.com"] = {
      oauth_token = token,
      user = user
    }
  }

  local json_str = vim.json.encode(hosts_data)
  local hosts_file = github_copilot_dir .. "/hosts.json"

  local file = io.open(hosts_file, "w")
  if not file then
    logger.error("Failed to open " .. hosts_file .. " for writing")
    return false
  end

  file:write(json_str)
  file:close()

  return true
end

-- Direct login with credentials
function M.direct_login()
  -- Create input for GitHub token
  vim.ui.input({
    prompt = "Enter your GitHub Personal Access Token: ",
    default = ""
  }, function(token)
      if not token or token == "" then
        echo("Login canceled")
        return
      end

      -- Get GitHub username from token
      local username = M.get_github_username(token)
      if not username then
        echo("Invalid token or network error")
        return
      end

      -- Write credentials to hosts.json
      if write_hosts_json(token, username) then
        echo("Authentication successful! Logged in as: " .. username)
      else
        echo("Failed to save authentication information")
      end
    end)
end

-- Function to get GitHub username using token
function M.get_github_username(token)
  local response = vim.fn.system('curl -s --header "Authorization: Bearer ' .. token .. '" https://api.github.com/user')
  if vim.v.shell_error ~= 0 then
    logger.error("GitHub API request failed: " .. response)
    return nil
  end

  local success, user_data = pcall(vim.json.decode, response)
  if not success or not user_data or not user_data.login then
    logger.error("Failed to parse GitHub user data")
    return nil
  end

  return user_data.login
end

function M.setup(client)
  local function copy_to_clipboard(str)
    vim.cmd(string.format(
      [[
        let @+ = "%s"
        let @* = "%s"
      ]],
      str,
      str
    ))
  end

  local function open_signin_popup(code, url)
    local lines = {
      " [Copilot] ",
      "",
      " First copy your one-time code: ",
      "   " .. code .. " ",
      " In your browser, visit: ",
      "   " .. url .. " ",
      "",
      " ...waiting, it might take a while and ",
      " this popup will auto close once done... ",
    }
    local height, width = #lines, math.max(unpack(vim.tbl_map(function(line)
      return #line
    end, lines)))

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    local winid = vim.api.nvim_open_win(bufnr, true, {
      relative = "editor",
      style = "minimal",
      border = "single",
      row = (vim.o.lines - height) / 2,
      col = (vim.o.columns - width) / 2,
      height = height,
      width = width,
    })
    vim.api.nvim_set_option_value("winhighlight", "Normal:Normal", { win = winid })

    return function()
      vim.api.nvim_win_close(winid, true)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end

  local initiate_setup = coroutine.wrap(function()
    local cserr, status = api.check_status(client)
    if cserr then
      echo(cserr)
      return
    end

    if status.user then
      echo("Authenticated as GitHub user: " .. status.user)
      return
    end

    local siierr, signin = api.sign_in_initiate(client)
    if siierr then
      echo(siierr)
      return
    end

    if not signin.verificationUri or not signin.userCode then
      echo("Failed to setup")
      return
    end

    copy_to_clipboard(signin.userCode)

    local close_signin_popup = open_signin_popup(signin.userCode, signin.verificationUri)

    -- Fixed parameter name from userId to userCode
    local sicerr, confirm = api.sign_in_confirm(client, { userCode = signin.userCode })

    close_signin_popup()

    if sicerr then
      echo(sicerr)
      return
    end

    if string.lower(confirm.status) ~= "ok" then
      echo("Authentication failure: " .. confirm.error.message)
      return
    end

    echo("Authenticated as GitHub user: " .. confirm.user)
  end)

  initiate_setup()
end

function M.signin()
  -- Ask the user if they want to use direct login or browser login
  vim.ui.select(
    {"Direct login with token", "Browser login (original method)"}, 
    {prompt = "Choose login method:"},
    function(choice)
      if choice == "Direct login with token" then
        M.direct_login()
      else
        c.use_client(function(client)
          M.setup(client)
        end)
      end
    end
  )
end

function M.signout()
  c.use_client(function(client)
    api.check_status(
      client,
      { options = { localChecksOnly = true } },
      ---@param status copilot_check_status_data
      function(err, status)
        if err then
          echo(err)
          return
        end

        if status.user then
          echo("Signed out as GitHub user " .. status.user)
        else
          echo("Not signed in")
        end

        api.sign_out(client, function() end)
      end
    )
  end)
end

-- Make find_config_path available to other functions
function M.find_config_path()
  local config = vim.fn.expand("$XDG_CONFIG_HOME")
  if config and vim.fn.isdirectory(config) > 0 then
    return config
  elseif vim.fn.has("win32") > 0 then
    config = vim.fn.expand("~/AppData/Local")
    if vim.fn.isdirectory(config) > 0 then
      return config
    end
  else
    config = vim.fn.expand("~/.config")
    if vim.fn.isdirectory(config) > 0 then
      return config
    else
      logger.error("could not find config path")
    end
  end
  return nil
end

local function oauth_user(token)
  return vim.fn.system('curl -s --header "Authorization: Bearer ' .. token .. '" https://api.github.com/user')
end

M.get_cred = function()
  local config_path = M.find_config_path()
  local hosts_file = config_path .. "/github-copilot/hosts.json"

  -- Check if hosts.json exists
  if vim.fn.filereadable(hosts_file) == 0 then
    logger.error("hosts.json file not found")
    return nil
  end

  local success, userdata = pcall(function()
    return vim.json.decode(vim.fn.readfile(hosts_file)[1])
  end)

  if not success or not userdata or not userdata["github.com"] then
    logger.error("Failed to read hosts.json or invalid format")
    return nil
  end

  local token = userdata["github.com"].oauth_token
  local user = userdata["github.com"].user or M.get_github_username(token)

  return { user = user, token = token }
end

return M
