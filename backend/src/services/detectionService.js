const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const historyService = require('./historyService');

// 配置 - 根据实际环境修改
const CONFIG = {
  // conda dl_train 环境的 Python 路径
  pythonPath: 'C:\\Users\\22069\\.conda\\envs\\dl_train\\python.exe',
  // 检测脚本路径
  detectScript: path.join(__dirname, '..', 'python', 'detect_api.py'),
  // 临时图片保存目录
  uploadDir: path.join(__dirname, '..', '..', 'uploads'),
};

// 确保上传目录存在
if (!fs.existsSync(CONFIG.uploadDir)) {
  fs.mkdirSync(CONFIG.uploadDir, { recursive: true });
}

class DetectionService {
  constructor() {
    this.detectionResult = {
      grade: null,
      gradeMethod: null,
      gradeConfidence: null,
      energyParam: null,
      standbyPower: null,
      isPass: false,
      defects: { isDamaged: false, isStained: false, isWrinkled: false },
      position: { isCorrect: true, x: 0, y: 0, deviation: 0 },
      labelFound: false,
      detections: [],
    };
    this.isDetecting = false;
  }

  getDetectionResult() {
    return this.detectionResult;
  }

  startDetection() {
    this.isDetecting = true;
    console.log('检测已开始');
  }

  stopDetection() {
    this.isDetecting = false;
    console.log('检测已停止');
  }

  importMLResult(result) {
    this.detectionResult = result;
    console.log('机器学习结果导入成功');
  }

  /**
   * 分析图片 - 调用 Python 检测脚本
   * @param {string} imageBase64 - Base64 编码的图片数据
   * @returns {Promise<Object>} 检测结果
   */
  async analyzeImage(imageBase64) {
    // 解码 base64 并保存为临时文件
    const matches = imageBase64.match(/^data:image\/(\w+);base64,(.+)$/);
    const ext = matches ? matches[1] : 'jpg';
    const base64Data = matches ? matches[2] : imageBase64;

    const tempFileName = `upload_${Date.now()}.${ext}`;
    const tempFilePath = path.join(CONFIG.uploadDir, tempFileName);

    try {
      // 保存图片到临时文件
      fs.writeFileSync(tempFilePath, Buffer.from(base64Data, 'base64'));
      console.log(`图片已保存: ${tempFilePath}`);

      // 调用 Python 检测脚本
      const result = await this.runDetection(tempFilePath);
      return result;
    } catch (error) {
      console.error('图片分析失败:', error);
      throw error;
    } finally {
      // 清理临时文件
      try {
        if (fs.existsSync(tempFilePath)) {
          fs.unlinkSync(tempFilePath);
        }
      } catch (e) {
        console.warn('清理临时文件失败:', e.message);
      }
    }
  }

  /**
   * 运行 Python 检测脚本
   * @param {string} imagePath - 图片文件路径
   * @returns {Promise<Object>} 检测结果
   */
  runDetection(imagePath) {
    return new Promise((resolve, reject) => {
      const python = spawn(CONFIG.pythonPath, [CONFIG.detectScript, imagePath]);

      let stdout = '';
      let stderr = '';

      python.stdout.on('data', (data) => {
        stdout += data.toString();
      });

      python.stderr.on('data', (data) => {
        stderr += data.toString();
        console.log(`Python stderr: ${data}`);
      });

      python.on('close', (code) => {
        if (code !== 0) {
          console.error(`Python 进程退出码: ${code}`);
          console.error(`stderr: ${stderr}`);
          reject(new Error(`检测失败 (退出码: ${code}): ${stderr.substring(0, 200)}`));
          return;
        }

        try {
          // 提取最后一行 JSON（跳过 Python 的调试输出）
          const lines = stdout.trim().split('\n');
          const jsonLine = lines[lines.length - 1];
          const result = JSON.parse(jsonLine);

          // 更新缓存结果 + 自动存入历史记录
          this.detectionResult = result;
          if (result.success) {
            historyService.addRecord(result);
            console.log('检测完成，已存入历史记录');
          }
          resolve(result);
        } catch (e) {
          console.error('解析 Python 输出失败:', stdout);
          reject(new Error('检测结果解析失败'));
        }
      });

      python.on('error', (err) => {
        console.error('启动 Python 进程失败:', err);
        reject(new Error(`启动检测引擎失败: ${err.message}`));
      });

      // 超时保护（60秒）
      setTimeout(() => {
        python.kill();
        reject(new Error('检测超时'));
      }, 60000);
    });
  }
}

module.exports = new DetectionService();
