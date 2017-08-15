local helpers = require "spec.helpers"
local cjson = require "cjson"

describe("Plugin: basic-auth (access)", function()
  local client, admin_client
  setup(function()
    helpers.run_migrations()
    assert(helpers.dao.apis:insert {
      name = "introspection-api",
      uris = { "/introspect" },
      upstream_url = "http://mockbin.com"
    })

    local api1 = assert(helpers.dao.apis:insert {
      name = "api-1",
      hosts = { "introspection.com" },
      upstream_url = "http://mockbin.com"
    })
    assert(helpers.dao.plugins:insert {
      name = "oauth2-introspection",
      api_id = api1.id,
      config = {
        introspection_url = string.format(
                      "http://%s:%s/introspect", 
                      helpers.test_conf.proxy_ip, 
                      helpers.test_conf.proxy_port),
        authorization_value = "hello",
        ttl = 1
      }
    })

    local api2 = assert(helpers.dao.apis:insert {
      name = "api-2",
      hosts = { "introspection2.com" },
      upstream_url = "http://mockbin.com"
    })
    assert(helpers.dao.plugins:insert {
      name = "oauth2-introspection",
      api_id = api2.id,
      config = {
        introspection_url = string.format(
                      "http://%s:%s/introspect", 
                      helpers.test_conf.proxy_ip, 
                      helpers.test_conf.proxy_port),
        authorization_value = "hello",
        hide_credentials = true
      }
    })

    assert(helpers.dao.consumers:insert {
      username = "bob"
    })
    local consumer = assert(helpers.dao.consumers:insert {
      username = "limited-bob"
    })
    assert(helpers.dao.plugins:insert {
      name = "correlation-id",
      api_id = api1.id,
      consumer_id = consumer.id,
      config = {},
    })

    assert(helpers.start_kong({
      custom_plugins = "introspection-endpoint, oauth2-introspection",
      lua_package_path = "?/init.lua;./kong/?.lua;./spec/fixtures/?.lua;/kong-plugin/spec/fixtures/custom_plugins/?.lua;;"
    }))

    client = helpers.proxy_client()
    admin_client = helpers.admin_client()

    local res = assert(admin_client:send {
      method = "POST",
      path = "/apis/introspection-api/plugins/",
      body = {
        name = "introspection-endpoint"
      },
      headers = {
        ["Content-Type"] = "application/json"
      }
    })
    assert.res_status(201, res)
  end)
  teardown(function()
    if admin_client then admin_client:close() end
    if client then client:close() end
    helpers.stop_kong()
  end)

  describe("Introspection Endpoint Mock", function()
    it("validates valid token", function()
      local res = assert(client:send {
        method = "POST",
        path = "/introspect",
        body = ngx.encode_args({token="valid"}),
        headers = {
          ["Content-Type"] = "application/x-www-form-urlencoded"
        }
      })

      local body = assert.res_status(200, res)
      assert.equal([[{"active":true}]], body)
    end)

    it("does not validate invalid token", function()
      local res = assert(client:send {
        method = "POST",
        path = "/introspect",
        body = ngx.encode_args({token="invalid"}),
        headers = {
          ["Content-Type"] = "application/x-www-form-urlencoded"
        }
      })

      local body = assert.res_status(200, res)
      assert.equal([[{"active":false}]], body)
    end)
  end)

  describe("Unauthorized", function()
    it("missing access_token", function()
      local res = assert(client:send {
        method = "GET",
        path = "/request",
        headers = {
          ["Host"] = "introspection.com"
        }
      })

      local body = assert.res_status(401, res)
      assert.equal([[{"error":"invalid_request","error_description":"The access token is missing"}]], body)
    end)
    it("invalid access_token", function()
      local res = assert(client:send {
        method = "GET",
        path = "/request?access_token=asd",
        headers = {
          ["Host"] = "introspection.com"
        }
      })

      local body = assert.res_status(401, res)
      assert.equal([[{"error":"invalid_token","error_description":"The access token is invalid or has expired"}]], body)
    end)
  end)

  describe("Authorized", function()
    it("validates a token in the querystring", function()
      local res = assert(client:send {
        method = "GET",
        path = "/request?access_token=valid",
        headers = {
          ["Host"] = "introspection.com"
        }
      })

      assert.res_status(200, res)
    end)
    it("validates a token in the body", function()
      local res = assert(client:send {
        method = "POST",
        path = "/request",
        body = ngx.encode_args({access_token="valid"}),
        headers = {
          ["Host"] = "introspection.com",
          ["Content-Type"] = "application/x-www-form-urlencoded"
        }
      })

      assert.res_status(200, res)
    end)
    it("validates a token in the header", function()
      local res = assert(client:send {
        method = "POST",
        path = "/request",
        headers = {
          ["Host"] = "introspection.com",
          ["Content-Type"] = "application/x-www-form-urlencoded",
          ["Authorization"] = "Bearer valid"
        }
      })

      local body = cjson.decode(assert.res_status(200, res))
      assert.is_nil(body.headers["x-consumer-username"])
    end)

    describe("Consumer", function()
      it("associates a consumer", function()
        local res = assert(client:send {
          method = "GET",
          path = "/request?access_token=valid_consumer",
          headers = {
            ["Host"] = "introspection.com"
          }
        })

        local body = cjson.decode(assert.res_status(200, res))
        assert.equal("bob", body.headers["x-consumer-username"])
        assert.is_string(body.headers["x-consumer-id"])
        assert.is_nil(res.headers["x-ratelimit-limit-minute"])
      end)
      it("invokes other consumer-specific plugins", function()
        local res = assert(client:send {
          method = "GET",
          path = "/request?access_token=valid_consumer_limited",
          headers = {
            ["Host"] = "introspection.com"
          }
        })

        local body = cjson.decode(assert.res_status(200, res))
        assert.equal("limited-bob", body.headers["x-consumer-username"])
        assert.is_string(body.headers["kong-request-id"])
      end)
    end)

    describe("upstream headers", function()
      it("appends upstream headers", function()
        local res = assert(client:send {
          method = "GET",
          path = "/request?access_token=valid_complex",
          headers = {
            ["Host"] = "introspection.com"
          }
        })

        local body = cjson.decode(assert.res_status(200, res))
        assert.equal("valid_complex", body.queryString.access_token)
        assert.equal("some_client_id", body.headers["x-credential-client-id"])
        assert.equal("some_username", body.headers["x-credential-username"])
        assert.equal("some_scope", body.headers["x-credential-scope"])
        assert.equal("some_sub", body.headers["x-credential-sub"])
        assert.equal("some_aud", body.headers["x-credential-aud"])
        assert.equal("some_iss", body.headers["x-credential-iss"])
        assert.equal("some_exp", body.headers["x-credential-exp"])
        assert.equal("some_iat", body.headers["x-credential-iat"])
      end)
    end)
    describe("hide credentials", function()
      it("appends upstream headers", function()
        local res = assert(client:send {
          method = "GET",
          path = "/request?access_token=valid_complex&hello=marco",
          headers = {
            ["Host"] = "introspection2.com"
          }
        })

        local body = cjson.decode(assert.res_status(200, res))
        assert.is_nil(body.queryString.access_token)
        assert.equal("some_client_id", body.headers["x-credential-client-id"])
        assert.equal("some_username", body.headers["x-credential-username"])
        assert.equal("some_scope", body.headers["x-credential-scope"])
        assert.equal("some_sub", body.headers["x-credential-sub"])
        assert.equal("some_aud", body.headers["x-credential-aud"])
        assert.equal("some_iss", body.headers["x-credential-iss"])
        assert.equal("some_exp", body.headers["x-credential-exp"])
        assert.equal("some_iat", body.headers["x-credential-iat"])
      end)
    end)
  end)
end)
