path    = require "path"
async   = require "async"
Primus  = require "primus"
Canvas  = require "canvas"
Twitter = require "twitter"
request = require "request"
express = require "express"

server_port = process.env.PORT || 8080

###
#  TWITTER
###
client = new Twitter
  consumer_key        : "BF7xLrSTZpKDXMX6NmDJKvu0E"
  consumer_secret     : "zbwY9lYJNeQwg5xiAHi3tY9ITFAEOuejcL65zzOvoB6NdrG3an"
  access_token_key    : "1954839354-UpU615rNLp3ArfA9yRuvY7SO7lKVF40JFYtaRng"
  access_token_secret : "UwWQaaHLJE9qEJyZ5QgGlLJe6p1DvECwLBJS7iYEFnmFL"

twitter_friends_ids = (login, size, cb)->
  ids_list = []
  max_ids = 5000
  next_cursor = 1
  params =
    screen_name : login
  params.count = size if size < max_ids

  async.whilst (()->
      if size - ids_list.length <= 0
        return false
      else
        params.count = size - ids_list.length if size - ids_list.length < max_ids
      if next_cursor > 0 then true else false
    ), ((callback)->
      client.get "friends/ids", params, (error, friends, response)->
        return callback error if error
        # console.log 'twitter_avatar_get', friends.ids.length
        ids_list = ids_list.concat friends.ids
        next_cursor = friends.next_cursor
        callback null
  ), (err)->
    # console.log 'cb 1', err, ids_list.length
    cb err, ids_list
  return

twitter_users_lookup = (ids_list, data, cb)->
  ret = []
  flw_sum = 0
  ids_str = ""

  async.whilst (()->
      ids_str = ids_list.splice(0, 100).join ","
      if ids_str then true else false
    ), ((callback)->
      client.get "users/lookup", {user_id : ids_str}, (error, users, response)->
        return callback error if error
        # console.log 'twitter_users_lookup', ret.length
        data.status null, "Twitter friends lookup #{ret.length}"
        for user in users
          ret.push
            id        : user.id
            img       : user.profile_image_url
            name      : user.name
            flw_count : user.followers_count
          flw_sum += user.followers_count
        callback null
  ), (err)->
    cb err,
      flw_sum   : flw_sum
      user_list : ret
  return

twitter_avatar_get = (obj, cb)->
  obj.status null, "Start twitter load data"
  twitter_friends_ids obj.login, obj.size, (err, ids_list)->
    return cb err[0].message if err?[0]?.code == 34
    if err?[0]?.code == 88
      obj.status err[0].message
    else
      obj.status null, "Start twitter load friends data"
    twitter_users_lookup ids_list, obj, (err, data)->
      if err
        if err[0]?.code == 88
          cb err[0].message  
        else
          cb err
        return    

      for user in data.user_list
        user.flw_percent = ( user.flw_count * 100 / data.flw_sum ).toFixed 2
      cb null, data.user_list
###
#  GENERATE COLLAGE IMG
###
Image = Canvas.Image
processed_client = {}

image_download = ( url, cb )->
  request.get {url: url, encoding: null}, (err, res, body)->
    return cb err if err
    return cb "404 on get #{res.request.href}" if res.statusCode != 200
    image = new Image()
    image.onerror = ()->
      cb arguments
    image.onload = ()->
      cb null, image
    image.src = new Buffer body, 'base64'


image_gen = (user_list, data, cb)->
  size    = user_list.length
  colums  = if size > 20 then 20 else size
  rows    = Math.ceil size/colums
  if user_list.length <= 1000
    width   = 48
    height  = 48
  else
    if user_list.length <= 5000
      width   = 36
      height  = 36
    else
      width   = 20
      height  = 20
  each_limit = 20

  canvas = new Canvas colums*width, rows*height
  ctx = canvas.getContext '2d'

  counter = 0
  async.eachLimit user_list, each_limit, (user, callback)->
    image_download user.img, (err, img)->
      if err || !img
        console.error err
        callback() 
        return
      x = (counter % colums) * width
      y = Math.floor(counter / colums) * height
      ctx.drawImage img, x, y, width, height
      counter++
      if counter % 100 == 0
        data.status null, "Image generate: #{(counter * 100 / size).toFixed(1)}%"
      callback()
  , (err)->
    console.error err if err
    return cb err if err
    canvas.toDataURL 'image/png', (err, url)->
      return cb err if err
      cb null, url

collage_gen = (login, size, spark)->
  if processed_client[spark.id]
    spark.write
      switch  : "error"
      message : "Wait for end of the previous request."
    return
  else
    processed_client[spark.id] = true

  data = 
    login : login
    size  : size
    status: (err, msg)->
      spark.write
        switch  : if err then "error" else "status"
        message : err || msg

  twitter_avatar_get data, (err, user_list)->
    if err
      console.error 'twitter_avatar_get', err
      data.status if typeof err == "string" then err else "Error on get twitter data. Try again later."
      processed_client[spark.id] = false
      return
    # console.log "img gen start", user_list.length
    data.status null, "Start image generate"
    image_gen user_list, data, (err, img_url)->
      processed_client[spark.id] = false
      if err
        console.error err
        spark.write
          switch  : "error"
          message : "Error on processing images. Try again later."
        return
      data.status null, "Process finished"
      spark.write
        switch  : "collage_img"
        src     : img_url

###
#  SERVER
###
app         = express()
server      = require('http').createServer app
validate =
  login : 
    min : 4
  size :
    min : 2
    max : 60000

app.use express.static path.join(__dirname, 'public')
app.get "/", (req, res)->
  res.render "index"

app.use (req, res)->
  res.status(404).send('<p>Sorry, we cannot find that!</p><a href="/">Go home</a>');

app.use (error, req, res)->
  res.status(500).send({ error: 'something blew up' });

server.listen server_port

console.log "Server listen on port: #{server_port}"

primus = new Primus server,
  transformer: 'socket.io'

primus.on 'connection', (spark)->
  spark.on "data", (data)->
    switch data.switch
      when '/api/v1/collage_get'
        if !data.login || data.login.length < validate.login.min
          spark.write
            switch  : "error"
            message : "Error! Wrong user login, min length: #{validate.login.min}"
          return
        if !data.size || isNaN(+data.size) || +data.size < validate.size.min || +data.size > validate.size.max
          spark.write
            switch  : "error"
            message : "Error! Wrong field 'size', number from #{validate.size.min} to #{validate.size.max}"
          return
        collage_gen data.login, +data.size, spark
      else
        cosole.error 'wrong switch', data
    return

primus.save __dirname + '/public/primus.js'

### TODO LIST
  - check empty response and other errors
  - make cache images
###