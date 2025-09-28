const express = require('express')
const product_detailsRouter = express.Router()

//导入添加项目路由处理函数
const product_detailsRouterHandler = require('./route_handler/product_detailsRouter_Handler')

//添加项目
product_detailsRouter.post('/insert', product_detailsRouterHandler.insertProduct)

//查询项目
product_detailsRouter.get('/select', product_detailsRouterHandler.selectProduct)

//根据code查询项目
product_detailsRouter.get('/select/:code', product_detailsRouterHandler.selectProductByCode)

module.exports = product_detailsRouter