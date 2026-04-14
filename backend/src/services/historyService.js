// 历史记录服务
class HistoryService {
  constructor() {
    this.records = [];
    this.nextId = 1;
  }

  // 保存一条检测记录
  addRecord(result) {
    const record = {
      id: String(this.nextId++),
      timestamp: new Date().toISOString().replace('T', ' ').substring(0, 19),
      productModel: result.productModel || '-',
      grade: result.grade || 0,
      energyParam: result.energyParam != null ? String(result.energyParam) : '未识别',
      standbyPower: result.standbyPower != null ? String(result.standbyPower) : '未识别',
      isDataMatch: result.labelFound || false,
      defects: result.defects || { isDamaged: false, isStained: false, isWrinkled: false },
      position: result.position || { isCorrect: true, x: 0, y: 0, deviation: 0 },
      isPass: result.isPass || false,
      hasDefect: result.hasDefect || false,
      gradeMethod: result.gradeMethod || null,
      labelConfidence: result.labelConfidence || null,
    };
    this.records.unshift(record); // 最新的在前面
    return record;
  }

  // 获取检测记录（带过滤）
  getDetectionRecords(filters) {
    let records = [...this.records];

    if (filters.productModel) {
      records = records.filter(r => r.productModel.includes(filters.productModel));
    }
    if (filters.startDate) {
      records = records.filter(r => r.timestamp >= filters.startDate);
    }
    if (filters.endDate) {
      const end = filters.endDate + ' 23:59:59';
      records = records.filter(r => r.timestamp <= end);
    }
    if (filters.status === 'pass') {
      records = records.filter(r => r.isPass);
    } else if (filters.status === 'fail') {
      records = records.filter(r => !r.isPass);
    }

    return records;
  }

  // 根据ID获取
  getDetectionRecordById(id) {
    const record = this.records.find(r => r.id === id);
    if (!record) throw new Error('记录未找到');
    return record;
  }

  // 获取统计信息
  getStats() {
    const total = this.records.length;
    const passCount = this.records.filter(r => r.isPass).length;
    const failCount = total - passCount;
    const damaged = this.records.filter(r => r.defects?.isDamaged).length;
    const stained = this.records.filter(r => r.defects?.isStained).length;
    const wrinkled = this.records.filter(r => r.defects?.isWrinkled).length;

    const deviations = this.records
      .map(r => r.position?.deviation || 0)
      .filter(d => d > 0);

    const avgDev = deviations.length > 0
      ? (deviations.reduce((a, b) => a + b, 0) / deviations.length).toFixed(2)
      : '0';
    const maxDev = deviations.length > 0 ? Math.max(...deviations).toFixed(2) : '0';
    const minDev = deviations.length > 0 ? Math.min(...deviations).toFixed(2) : '0';

    return {
      total, passCount, failCount,
      passRate: total > 0 ? Math.round(passCount / total * 100) : 0,
      damaged, stained, wrinkled,
      avgDev, maxDev, minDev,
    };
  }

  // 导出CSV
  exportDetectionRecords(filters) {
    const records = this.getDetectionRecords(filters);
    let csv = '\uFEFFID,时间,产品型号,能效等级,能效参数,待机功率,数据匹配,破损,污渍,褶皱,位置正确,偏差,检测结果\n';
    records.forEach(r => {
      csv += [
        r.id, r.timestamp, r.productModel,
        r.grade ? `${r.grade}级` : '未识别',
        r.energyParam, r.standbyPower,
        r.isDataMatch ? '是' : '否',
        r.defects.isDamaged ? '是' : '否',
        r.defects.isStained ? '是' : '否',
        r.defects.isWrinkled ? '是' : '否',
        r.position.isCorrect ? '是' : '否',
        r.position.deviation,
        r.isPass ? '通过' : '失败',
      ].join(',') + '\n';
    });
    return csv;
  }
}

module.exports = new HistoryService();
