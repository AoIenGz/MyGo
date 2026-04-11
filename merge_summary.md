此次合并添加了完整的后端API服务架构，包括检测、历史记录和产品管理功能，并优化了前端界面交互。同时实现了前后端数据交互，支持实时检测、历史记录查询和产品管理等核心功能。
| 文件 | 变更 |
|------|---------|
| backend/src/api/detectionRoutes.js | - 新增检测相关API路由，包括获取检测结果、开始/停止检测、导入机器学习结果等功能 |
| backend/src/services/detectionService.js | - 新增检测服务，提供检测结果管理、检测状态控制和机器学习结果导入功能 |
| backend/src/api/historyRoutes.js | - 新增历史记录相关API路由，支持获取检测记录、单个记录详情和导出CSV功能 |
| backend/src/services/historyService.js | - 新增历史记录服务，提供检测记录管理、过滤和导出功能 |
| backend/src/api/productRoutes.js | - 新增产品相关API路由，支持产品的增删改查操作 |
| backend/src/services/productService.js | - 新增产品服务，提供产品数据管理功能 |
| backend/src/server.js | - 新增服务器主文件，集成所有API路由和中间件配置 |
| entry/src/main/ets/pages/Index.ets | - 添加API服务类，实现与后端的交互<br>- 增加开始/停止检测、导入ML结果等功能<br>- 优化界面布局和样式，提升用户体验 |