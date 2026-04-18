const express = require('express');
const cors = require('cors');
const { initDatabase } = require('./db/database');
const detectionRoutes = require('./api/detectionRoutes');
const productRoutes = require('./api/productRoutes');
const historyRoutes = require('./api/historyRoutes');

const app = express();
const PORT = process.env.PORT || 3000;

// 中间件
app.use(cors());
app.use(express.json({ limit: '50mb' }));
app.use(express.urlencoded({ extended: true, limit: '50mb' }));

// 路由
app.use('/api/detection', detectionRoutes);
app.use('/api/products', productRoutes);
app.use('/api/history', historyRoutes);

// 健康检查
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'ok' });
});

// 启动服务器（先初始化数据库）
async function start() {
  await initDatabase();
  app.listen(PORT, () => {
    console.log(`Server running on port ${PORT}`);
  });
}

start().catch(err => {
  console.error('服务启动失败:', err);
  process.exit(1);
});

module.exports = app;