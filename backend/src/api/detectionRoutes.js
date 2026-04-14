const express = require('express');
const router = express.Router();
const detectionService = require('../services/detectionService');

// 获取实时检测结果
router.get('/result', (req, res) => {
  try {
    const result = detectionService.getDetectionResult();
    res.status(200).json(result);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// 开始检测
router.post('/start', (req, res) => {
  try {
    detectionService.startDetection();
    res.status(200).json({ message: '检测已开始' });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// 停止检测
router.post('/stop', (req, res) => {
  try {
    detectionService.stopDetection();
    res.status(200).json({ message: '检测已停止' });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// 导入机器学习结果
router.post('/import-ml-result', (req, res) => {
  try {
    const { result } = req.body;
    detectionService.importMLResult(result);
    res.status(200).json({ message: '机器学习结果导入成功' });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// 图片分析 - 接收 base64 图片并调用 Python 检测
router.post('/analyze', async (req, res) => {
  try {
    const { image } = req.body;

    if (!image) {
      return res.status(400).json({ success: false, error: '未提供图片数据' });
    }

    console.log('收到图片分析请求, 数据长度:', image.length);
    const result = await detectionService.analyzeImage(image);
    res.status(200).json(result);
  } catch (error) {
    console.error('图片分析错误:', error);
    res.status(500).json({ success: false, error: error.message });
  }
});

module.exports = router;
