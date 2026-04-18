const initSqlJs = require('sql.js');
const path = require('path');
const fs = require('fs');

const DB_PATH = path.join(__dirname, '..', '..', 'data', 'detection.db');

let db = null;

async function initDatabase() {
  const SQL = await initSqlJs();

  // 如果已有数据库文件则加载，否则新建
  if (fs.existsSync(DB_PATH)) {
    const buffer = fs.readFileSync(DB_PATH);
    db = new SQL.Database(buffer);
  } else {
    db = new SQL.Database();
  }

  // 建表
  db.run(`
    CREATE TABLE IF NOT EXISTS products (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      model TEXT NOT NULL,
      energy_grade INTEGER,
      power_consumption REAL
    )
  `);

  db.run(`
    CREATE TABLE IF NOT EXISTS detection_records (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      timestamp TEXT NOT NULL,
      product_model TEXT DEFAULT '-',
      grade INTEGER DEFAULT 0,
      energy_param TEXT DEFAULT '未识别',
      standby_power TEXT DEFAULT '未识别',
      is_data_match INTEGER DEFAULT 0,
      defects TEXT DEFAULT '{}',
      position TEXT DEFAULT '{}',
      is_pass INTEGER DEFAULT 0,
      has_defect INTEGER DEFAULT 0,
      grade_method TEXT,
      label_confidence REAL
    )
  `);

  // 插入默认产品（仅当表为空时）
  const count = db.exec('SELECT COUNT(*) as cnt FROM products');
  if (count[0] && count[0].values[0][0] === 0) {
    db.run("INSERT INTO products (model, energy_grade, power_consumption) VALUES ('HB-2024-001', 1, 120)");
    db.run("INSERT INTO products (model, energy_grade, power_consumption) VALUES ('HB-2024-002', 2, 150)");
    db.run("INSERT INTO products (model, energy_grade, power_consumption) VALUES ('HB-2024-003', 3, 180)");
  }

  save();
  console.log('数据库初始化完成:', DB_PATH);
  return db;
}

function getDb() {
  return db;
}

function save() {
  if (!db) return;
  const data = db.export();
  const buffer = Buffer.from(data);
  fs.writeFileSync(DB_PATH, buffer);
}

module.exports = { initDatabase, getDb, save };
