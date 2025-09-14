const db = require("../../database/index");
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');

//注册新用户处理函数
exports.regUser = (req, res) => {
  //获取用户提交数据
  const userinfo = req.body;

  //定义SQL语句,查询用户身份证号
  console.log('用户:' + userinfo.user_email)
  const sqlStr = 'select * from user where user_email=?'
  db.query(sqlStr, [userinfo.user_email], (err, results) => {

    // 执行SQL语句失败
    if (err) return res.cc(err)

    //判断身份证号是否被占用
    if (results.length > 0) { return res.cc('该邮箱已被注册!') }

    // 调用bcrypt.hashSync()对密码进行加密(不能解密，只能验证)
    console.log('注册用户未加密密码:' + userinfo.user_password)
    userinfo.user_password = bcrypt.hashSync(userinfo.user_password, 10)
    console.log('注册用户加密密码' + userinfo.user_password)

    // 定义插入用户数据的SQL语句
    const sql = 'insert into user set ?'
    db.query(sql, { user_name: userinfo.user_name, user_password: userinfo.user_password, user_id: userinfo.user_id, user_email: userinfo.user_email, user_phone: userinfo.user_phone }, (err, results) => {

      // 执行SQL语句失败
      if (err) return res.cc(err)
      // 执行SQL语句成功，但影响行数不为1
      if (results.affectedRows !== 1) return res.cc('注册用户失败，请稍后再试！')

      // 注册用户成功
      console.log('注册用户成功!')
      res.send({ status: 0, message: '注册成功!!' });
    })
  })
}

//登录处理函数
exports.login = (req, res) => {
  //获取用户提交数据
  const userinfo = req.body

  const sql = 'select * from user where user_email=?'
  db.query(sql, [userinfo.user_email], (err, results) => {
    // 执行SQL语句失败
    if (err) return res.cc(err)
    // 执行SQL语句成功，但是查询到数据条数不等于1
    if (results.length !== 1) return res.cc('用户未注册,登录失败！')

    // 拿着用户输入的密码，和数据库中存储的密码进行对比
    const compareResult = bcrypt.compareSync(userinfo.user_password, results[0].user_password)
    if (!compareResult) return res.cc('密码错误,登录失败！')

    //在服务器端生成token字符串并擦除密码及id等敏感信息
    const user = { ...results[0], user_password: '', user_email: '' }

    //对用户信息进行加密，生成token字符串
    const tokenStr = jwt.sign(user, process.env.jwt_SecretKey, { expiresIn: process.env.expiresIn })

    console.log('用户: ' + userinfo.user_email + ' 登录成功！')

    res.send({
      status: 0,
      message: '登录成功！',
      token: 'Bearer ' + tokenStr,
    })
  })
}