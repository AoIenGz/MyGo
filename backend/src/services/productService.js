const { getDb, save } = require('../db/database');

class ProductService {
  getProducts() {
    const db = getDb();
    const stmt = db.prepare('SELECT * FROM products');
    const products = [];
    while (stmt.step()) {
      const row = stmt.getAsObject();
      products.push({
        id: String(row.id),
        model: row.model,
        energyGrade: row.energy_grade,
        powerConsumption: row.power_consumption,
      });
    }
    stmt.free();
    return products;
  }

  getProductById(id) {
    const db = getDb();
    const stmt = db.prepare('SELECT * FROM products WHERE id = ?');
    stmt.bind([id]);
    if (stmt.step()) {
      const row = stmt.getAsObject();
      stmt.free();
      return {
        id: String(row.id),
        model: row.model,
        energyGrade: row.energy_grade,
        powerConsumption: row.power_consumption,
      };
    }
    stmt.free();
    throw new Error('产品未找到');
  }

  addProduct(productData) {
    const db = getDb();
    db.run(
      'INSERT INTO products (model, energy_grade, power_consumption) VALUES (?, ?, ?)',
      [productData.model, productData.energyGrade, productData.powerConsumption]
    );
    const rs = db.exec('SELECT last_insert_rowid()');
    const id = rs[0] ? rs[0].values[0][0] : 0;
    save();
    return {
      id: String(id),
      model: productData.model,
      energyGrade: productData.energyGrade,
      powerConsumption: productData.powerConsumption,
    };
  }

  updateProduct(id, productData) {
    const db = getDb();
    const existing = this.getProductById(id);
    const model = productData.model || existing.model;
    const energyGrade = productData.energyGrade !== undefined ? productData.energyGrade : existing.energyGrade;
    const powerConsumption = productData.powerConsumption !== undefined ? productData.powerConsumption : existing.powerConsumption;
    db.run(
      'UPDATE products SET model = ?, energy_grade = ?, power_consumption = ? WHERE id = ?',
      [model, energyGrade, powerConsumption, id]
    );
    save();
    return { id: String(id), model, energyGrade, powerConsumption };
  }

  deleteProduct(id) {
    const db = getDb();
    this.getProductById(id);
    db.run('DELETE FROM products WHERE id = ?', [id]);
    save();
  }
}

module.exports = new ProductService();
