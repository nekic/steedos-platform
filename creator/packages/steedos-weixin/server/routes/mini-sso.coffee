request = Npm.require("request")

getWeiXinSession = (appId, secret, code, cb)->
	request.get {
		url: "https://api.weixin.qq.com/sns/jscode2session?appid=#{appId}&secret=#{secret}&js_code=#{code}&grant_type=authorization_code"
	}, (err, httpResponse, body)->
		cb err, httpResponse, body
		if err
			console.error('upload failed:', err)
			return
		if httpResponse.statusCode == 200
			return

getWeiXinSessionAsync = Meteor.wrapAsync(getWeiXinSession);

setNewToken = (userId, appId, openid)->
	authToken = Accounts._generateStampedLoginToken()
	token = authToken.token
	hashedToken = Accounts._hashStampedToken authToken
	hashedToken.app_id = appId
	hashedToken.open_id = openid
	hashedToken.token = token
	Accounts._insertHashedLoginToken userId, hashedToken
	return token

#TODO 处理unionid
JsonRoutes.add 'post', '/mini/vip/sso', (req, res, next) ->
	try
		code = req.query.code
		old_user_id = req.query.old_user_id
		old_auth_token = req.query.old_auth_token
		space_id = req.query.space_id

		appId = req.headers["appid"]

		secret = Meteor.settings.weixin.appSecret[appId]
		if !secret
			throw new Meteor.Error(500, "无效的appId #{appId}")

		if !code
			throw new Meteor.Error(401, "miss code")

		resData = getWeiXinSessionAsync appId, secret, code

		wxSession = JSON.parse(resData.body)

		sessionKey = wxSession.session_key

		console.log("sessionKey", sessionKey)

		openid = wxSession.openid

		#	unionid = wxSession.unionid

		if !openid
			throw new Meteor.Error(401, "miss openid")

		ret_data = {}

		user_openid = Creator.getCollection("users").findOne({
			"services.weixin.openid.appid": appId,
			"services.weixin.openid._id": openid
		}, {fields: {_id: 1}})

		if !user_openid
			unionid = ""
			locale = "zh-cn"
			phoneNumber = ""
			userId = WXMini.newUser(appId, openid, unionid, "", locale, phoneNumber)

			authToken = setNewToken(userId, appId, openid)

			ret_data = {
				open_id: openid
				user_id: userId
				auth_token: authToken
			}
		else
			if user_openid._id == old_user_id
				if Steedos.checkAuthToken(old_user_id, old_auth_token)
					ret_data = {
						open_id: openid
						user_id: old_user_id
						auth_token: old_auth_token
					}
				else
					authToken = setNewToken(old_user_id, appId, openid)
					ret_data = {
						open_id: openid
						user_id: old_user_id
						auth_token: authToken
					}
			else
				authToken = setNewToken(user_openid._id, appId, openid)
				ret_data = {
					open_id: openid
					user_id: user_openid._id
					auth_token: authToken
				}

		space_users = Creator.getCollection("space_users").find({
			user: ret_data.user_id
		}, {fields: {space: 1, profile: 1}}).fetch()

		if space_users.length
			spaces = Creator.getCollection("spaces").find({
				_id:{$in:_.pluck(space_users,"space")}
			}, {fields: {name: 1,admins: 1, owner: 1}}).fetch()
			space_users = space_users.map((su)->
				s = _.findWhere(spaces, {_id: su.space})
				s = _.extend(su, s)
				isSpaceAdmin = s.admins?.indexOf(ret_data.user_id) > -1
				if isSpaceAdmin
					s.profile = 'admin'
				delete s.admins
				delete s.space
				return s
			)

		ret_data.my_spaces = space_users

		#设置sessionKey
		Creator.getCollection("users").direct.update({
			_id: ret_data.user_id,
			"services.weixin.openid.appid": appId,
			"services.weixin.openid._id": openid
		}, {$set: {"services.weixin.openid.$.session_key": sessionKey}})

		user = Creator.getCollection("users").findOne({_id: ret_data.user_id}, {fields: {name: 1, profile: 1, mobile: 1}})

		ret_data.name = user.name
		ret_data.mobile = user.mobile
		ret_data.sex = user.profile?.sex
		ret_data.birthdate = user.profile?.birthdate
		ret_data.avatar = user.profile?.avatar

		JsonRoutes.sendResult res, {
			code: 200,
			data: ret_data
		}
		return

	catch e
		console.error e.stack
		JsonRoutes.sendResult res, {
			code: e.error
			data: {errors: e.reason || e.message}
		}

