// 产品服务
class ProductService {
  constructor() {
    this.products = [
      { id: '1', model: 'HB-2024-001', energyGrade: 1, powerConsumption: 120 },
      { id: '2', model: 'HB-2024-002', energyGrade: 2, powerConsumption: 150 },
      { id: '3', model: 'HB-2024-003', energyGrade: 3, powerConsumption: 180 },
    ];
    this.nextId = 4;
  }

  getProducts() {
    return this.products;
  }

  getProductById(id) {
    const product = this.products.find(p => p.id === id);
    if (!product) throw new Error('产品未找到');
    return product;
  }

  addProduct(productData) {
    const newProduct = {
      id: String(this.nextId++),
      model: productData.model,
      energyGrade: productData.energyGrade,
      powerConsumption: productData.powerConsumption,
    };
    this.products.push(newProduct);
    return newProduct;
  }

  updateProduct(id, productData) {
    const index = this.products.findIndex(p => p.id === id);
    if (index === -1) throw new Error('产品未找到');
    this.products[index] = { ...this.products[index], ...productData };
    return this.products[index];
  }

  deleteProduct(id) {
    const index = this.products.findIndex(p => p.id === id);
    if (index === -1) throw new Error('产品未找到');
    this.products.splice(index, 1);
  }
}

module.exports = new ProductService();
