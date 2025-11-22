# Flutter 云同步集成指南

## 📦 已添加的依赖

```yaml
dependencies:
  dio: ^5.4.0  # HTTP客户端
  sqflite: ^2.3.0  # 本地数据库
  path_provider: ^2.1.2  # 文件路径
  flutter_secure_storage: ^9.0.0  # 安全存储Token
```

运行 `flutter pub get` 安装依赖。

## 🏗️ 代码结构

```
lib/src/features/sync/
├── models/
│   ├── user_model.dart           # 用户模型
│   └── sync_models.dart           # 同步数据模型
├── data/
│   ├── api_client.dart            # API客户端（Dio）
│   └── local_database.dart        # 本地SQLite数据库
├── repositories/
│   └── sync_repository.dart       # 同步业务逻辑
└── providers/
    ├── auth_provider.dart         # 认证状态管理
    └── sync_provider.dart         # 同步状态管理
```

## 🚀 使用方法

### 1. 配置API地址

编译时指定：
```bash
flutter run --dart-define=API_BASE_URL=http://your-server:8000
```

或在代码中修改 `auth_provider.dart`:
```dart
const baseUrl = 'http://your-server:8000';
```

### 2. 在应用中使用

#### 初始化（在main.dart）

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'src/features/sync/providers/auth_provider.dart';
import 'src/features/sync/providers/sync_provider.dart';

void main() {
  runApp(
    const ProviderScope(
      child: MyApp(),
    ),
  );
}
```

#### 登录界面示例

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mygril_flutter/src/features/sync/providers/auth_provider.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({Key? key}) : super(key: key);

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  Future<void> _handleLogin() async {
    final authNotifier = ref.read(authProvider.notifier);
    final success = await authNotifier.login(
      username: _usernameController.text,
      password: _passwordController.text,
    );

    if (success && mounted) {
      // 登录成功，跳转到主页
      Navigator.of(context).pushReplacementNamed('/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('登录')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(labelText: '用户名'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              decoration: const InputDecoration(labelText: '密码'),
              obscureText: true,
            ),
            const SizedBox(height: 24),
            if (authState.error != null)
              Text(
                authState.error!,
                style: const TextStyle(color: Colors.red),
              ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: authState.isLoading ? null : _handleLogin,
              child: authState.isLoading
                  ? const CircularProgressIndicator()
                  : const Text('登录'),
            ),
          ],
        ),
      ),
    );
  }
}
```

#### 触发同步

```dart
// 在某个页面中
class MyHomePage extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncState = ref.watch(syncProvider);
    final authState = ref.watch(authProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text('主页'),
        actions: [
          // 显示同步状态
          if (syncState.isSyncing)
            Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          
          // 手动同步按钮
          if (authState.isLoggedIn)
            IconButton(
              icon: Icon(Icons.sync),
              onPressed: syncState.isSyncing
                  ? null
                  : () {
                      ref.read(syncProvider.notifier).syncAll();
                    },
            ),
        ],
      ),
      body: Column(
        children: [
          // 显示登录状态
          if (authState.isLoggedIn)
            ListTile(
              title: Text('已登录: ${authState.user?.username}'),
              trailing: TextButton(
                onPressed: () {
                  ref.read(authProvider.notifier).logout();
                },
                child: Text('退出登录'),
              ),
            )
          else
            ListTile(
              title: Text('未登录'),
              trailing: TextButton(
                onPressed: () {
                  Navigator.of(context).pushNamed('/login');
                },
                child: Text('去登录'),
              ),
            ),
          
          // 显示同步状态
          if (syncState.lastSyncTime != null)
            ListTile(
              title: Text('最后同步时间'),
              subtitle: Text(syncState.lastSyncTime.toString()),
            ),
        ],
      ),
    );
  }
}
```

## 🔄 自动同步策略

已实现自动同步：
- ✅ 应用启动时检查登录状态
- ✅ 登录成功后自动同步一次
- ✅ 每5分钟自动同步（后台）
- ✅ 数据变更后标记为未同步，下次同步时上传

可在设置中关闭自动同步：
```dart
ref.read(syncProvider.notifier).toggleAutoSync();
```

## 📝 集成到现有代码

### 1. 联系人创建时

当用户创建新联系人时，保存到本地数据库：

```dart
import 'package:mygril_flutter/src/features/sync/data/local_database.dart';
import 'package:mygril_flutter/src/features/sync/models/sync_models.dart';
import 'package:uuid/uuid.dart';

Future<void> createContact(String name, String avatarUrl) async {
  final db = LocalSyncDatabase.instance;
  
  final contact = ContactSync(
    contactId: const Uuid().v4(),
    name: name,
    avatarUrl: avatarUrl,
    characterData: {
      'system_prompt': '你是一个温柔的女友...',
      // 其他角色设定
    },
    updatedAt: DateTime.now(),
  );
  
  // 保存到本地，标记为未同步
  await db.upsertContact(contact, isSynced: false);
  
  // 触发同步（可选，会自动同步）
  // ref.read(syncProvider.notifier).syncContacts();
}
```

### 2. 消息发送时

```dart
Future<void> sendMessage(String contactId, String content) async {
  final db = LocalSyncDatabase.instance;
  
  final message = MessageSync(
    messageId: const Uuid().v4(),
    contactId: contactId,
    role: 'user',
    content: content,
    createdAt: DateTime.now(),
  );
  
  // 保存到本地，标记为未同步
  await db.insertMessage(message, isSynced: false);
}
```

## ⚙️ 高级配置

### 修改同步间隔

在 `sync_provider.dart` 中修改：
```dart
// 从5分钟改为10分钟
_autoSyncTimer = Timer.periodic(const Duration(minutes: 10), (_) {
  // ...
});
```

### 冲突处理

目前策略：服务器版本优先（Server-Wins）

如需自定义冲突处理，修改 `sync_repository.dart` 中的同步逻辑。

## 🐛 调试

查看同步日志：
```dart
// 已在代码中添加打印
// ✅ 上传了 X 个联系人
// ✅ 从服务器拉取了 X 个联系人
// 🔄 开始全量同步...
// ❌ 同步失败: xxx
```

## 📚 下一步

1. **集成到现有UI**: 在设置页添加登录/同步选项
2. **优化同步时机**: 根据应用场景调整自动同步策略
3. **错误处理**: 添加友好的错误提示
4. **离线支持**: 完善离线模式体验
5. **冲突解决UI**: 当出现冲突时，让用户选择保留哪个版本

## 🆘 常见问题

**Q: Token存在哪里？**  
A: 使用 `flutter_secure_storage` 安全存储在系统钥匙串。

**Q: 如何清除所有同步数据？**  
A: 
```dart
final db = LocalSyncDatabase.instance;
await db.clearAll();
```

**Q: 如何查看当前同步状态？**  
A:
```dart
final syncState = ref.watch(syncProvider);
print('是否在同步: ${syncState.isSyncing}');
print('最后同步时间: ${syncState.lastSyncTime}');
```

**Q: 如何禁用自动同步？**  
A:
```dart
ref.read(syncProvider.notifier).toggleAutoSync();
```
