import 'package:flutter/material.dart';

import '../../app/services/feiniu/account_entry.dart';
import '../../app/services/feiniu/account_store.dart';
import '../../app/services/feiniu/auth_service.dart';
import '../../app/services/player_service.dart';
import '../../components/index.dart';
import '../login/login_page.dart';

/// 账号切换页
///
/// 列出所有已保存账号：可一键切换、重命名（备注）、编辑服务器地址、删除；
/// 并可添加新账号（登录成功后自动切换过去，旧账号保留）。
/// 该页挂载在 root 导航器上（见 AppRoutes.accounts 的调用方），切换账号时
/// 即使整个主外壳重建，本页仍可存活继续操作。
class AccountSwitchPage extends StatefulWidget {
  const AccountSwitchPage({super.key});

  @override
  State<AccountSwitchPage> createState() => _AccountSwitchPageState();
}

class _AccountSwitchPageState extends State<AccountSwitchPage> {
  bool _switching = false;

  @override
  Widget build(BuildContext context) {
    return AppNavigationModeBuilder(
      builder: (context, useBottomNavigation) {
        final bottomPadding = AppPageScaffold.scrollableBottomPadding(
          context,
          hasBottomNav: false,
          showMiniPlayer: false,
        );
        return AppPageScaffold(
          extendBodyBehindAppBar: true,
          showMiniPlayer: false,
          appBar: AppTopBar(
            title: '账号',
            showBackButton: true,
            backgroundColor: Colors.transparent,
            elevation: 0,
          ),
          body: ValueListenableBuilder<List<AccountEntry>>(
            valueListenable: AccountStore.instance.accounts,
            builder: (context, accounts, _) {
              final currentId = AccountStore.instance.currentAccountId.value;
              final current =
                  accounts.where((a) => a.id == currentId).firstOrNull;
              return ListView(
                padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
                children: [
                  if (current != null) ...[
                    _buildCurrentCard(context, current),
                    const SizedBox(height: 20),
                  ],
                  AppSettingSection(
                    title: '已保存账号',
                    children: [
                      if (accounts.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 20,
                          ),
                          child: Center(
                            child: Text(
                              '暂无已保存账号',
                              style: TextStyle(
                                fontSize: 13,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        )
                      else
                        for (final account in accounts)
                          _buildAccountTile(context, account),
                    ],
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    height: 48,
                    child: FilledButton.icon(
                      onPressed: _switching ? null : _addNewAccount,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('添加新账号'),
                      style: FilledButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 退出当前账号（账号保留在列表中，可一键重新进入）
                  ValueListenableBuilder<bool>(
                    valueListenable: AuthService.instance.isLoggedIn,
                    builder: (context, isLoggedIn, _) {
                      if (!isLoggedIn) return const SizedBox.shrink();
                      return SizedBox(
                        height: 48,
                        child: OutlinedButton.icon(
                          onPressed: _switching ? null : _confirmLogout,
                          icon: const Icon(Icons.logout_rounded),
                          label: const Text('退出登录'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.error,
                            side: BorderSide(
                              color: Theme.of(
                                context,
                              ).colorScheme.error.withValues(alpha: 0.5),
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  /// 当前账号卡片
  Widget _buildCurrentCard(BuildContext context, AccountEntry account) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: scheme.primary.withValues(alpha: 0.16),
            child: Text(
              account.username.isNotEmpty
                  ? account.username.characters.first
                  : '?',
              style: TextStyle(
                color: scheme.primary,
                fontWeight: FontWeight.w700,
                fontSize: 20,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  account.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${account.username} · ${account.serverLabel}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.9),
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: BorderRadius.circular(99),
            ),
            child: Text(
              '当前',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: scheme.onPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountTile(BuildContext context, AccountEntry account) {
    final scheme = Theme.of(context).colorScheme;
    final isCurrent = account.id == AccountStore.instance.currentAccountId.value;
    return AppListTile(
      leading: CircleAvatar(
        radius: 17,
        backgroundColor: scheme.primary.withValues(alpha: 0.12),
        child: Text(
          account.username.isNotEmpty
              ? account.username.characters.first
              : '?',
          style: TextStyle(
            color: scheme.primary,
            fontWeight: FontWeight.w700,
            fontSize: 15,
          ),
        ),
      ),
      title: account.displayName,
      subtitle: '${account.username} · ${account.serverLabel}',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isCurrent)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(99),
              ),
              child: Text(
                '当前',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
            )
          else if (account.isLoggedIn)
            // 已登录账号：点击可切换到此账号
            Icon(
              Icons.swap_horiz_rounded,
              size: 18,
              color: scheme.primary.withValues(alpha: 0.7),
            )
          else
            // 未登录的账号：需重新登录后使用
            Icon(
              Icons.login_rounded,
              size: 18,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
          PopupMenuButton<_AccountAction>(
            tooltip: '账号操作',
            icon: Icon(
              Icons.more_vert_rounded,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            onSelected: (action) => _handleAction(context, account, action),
            itemBuilder: (context) => [
              // 当前账号无需切换，不显示「切换账号」
              if (!isCurrent)
                const PopupMenuItem(
                  value: _AccountAction.switch_,
                  child: Text('切换账号'),
                ),
              const PopupMenuItem(
                value: _AccountAction.edit,
                child: Text('编辑'),
              ),
              const PopupMenuItem(
                value: _AccountAction.delete,
                child: Text(
                  '删除',
                  style: TextStyle(color: Colors.redAccent),
                ),
              ),
            ],
          ),
        ],
      ),
      onTap: () => _switchTo(context, account.id),
    );
  }

  Future<void> _handleAction(
    BuildContext context,
    AccountEntry account,
    _AccountAction action,
  ) async {
    switch (action) {
      case _AccountAction.switch_:
        await _switchTo(context, account.id);
        break;
      case _AccountAction.edit:
        // 跳转到登录页编辑账号：预填该账号字段，改完重新登录后写回
        // （保留原 id 与自定义备注）。「添加新账号」与「编辑账号」共用
        // 登录页，登录成功后均返回本页。
        _editAccount(context, account);
        break;
      case _AccountAction.delete:
        await _confirmDelete(context, account);
        break;
    }
  }

  /// 跳转到登录页编辑账号
  void _editAccount(BuildContext context, AccountEntry account) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LoginPage(editAccount: account),
      ),
    );
  }

  Future<void> _switchTo(BuildContext context, String id) async {
    if (id == AccountStore.instance.currentAccountId.value) return;
    if (_switching) return;
    setState(() => _switching = true);
    try {
      final ok = await AccountStore.instance.switchTo(id);
      if (!context.mounted) return;
      if (ok) {
        // 切换成功：关闭账号切换页，回到设置页
        Navigator.of(context).pop();
      } else {
        // 无 token 且无密码可自动登录：激活后门控会回退到登录页
        AppToast.show(
          context,
          '该账号未登录，请重新登录',
          type: ToastType.info,
        );
      }
    } catch (_) {
      if (context.mounted) {
        AppToast.show(context, '切换失败', type: ToastType.error);
      }
    } finally {
      if (mounted) {
        setState(() => _switching = false);
      }
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    AccountEntry account,
  ) async {
    // 当前激活账号（且已登录）不允许删除，避免删掉正在使用的登录态
    final isCurrentActive = account.id ==
            AccountStore.instance.currentAccountId.value &&
        AuthService.instance.isLoggedIn.value;
    if (isCurrentActive) {
      if (context.mounted) {
        AppToast.show(context, '请先切换或退出当前账号后再删除', type: ToastType.info);
      }
      return;
    }
    final confirmed = await AppDialog.showConfirm(
      context,
      title: '删除账号',
      content: '确定删除「${account.displayName}」吗？\n删除后需重新登录才能使用。',
      confirmText: '删除',
      isDestructive: true,
    );
    if (confirmed != true) return;
    await AccountStore.instance.remove(account.id);
    if (context.mounted) {
      AppToast.show(context, '账号已删除', type: ToastType.success);
    }
  }

  void _addNewAccount() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const LoginPage(isAddMode: true)));
  }

  /// 退出当前账号：停止播放 → 登出 → 关闭本页（门控自动切回登录页）。
  Future<void> _confirmLogout() async {
    final confirmed = await AppDialog.showConfirm(
      context,
      title: '退出登录',
      content: '退出登录后，账号及其登录状态将保留在账号列表中，可一键重新登录。',
      confirmText: '退出',
      isDestructive: true,
    );
    if (confirmed != true) return;
    // 退出登录前先停止音乐播放
    try {
      await PlayerService.instance.stopAndClear();
    } catch (_) {}
    await AuthService.instance.logout();
    // 退出后 isLoggedIn 变化，门控自动把主外壳切回登录页。
    // 若本页挂在外壳的嵌套导航器上（随外壳一并卸载），无需手动 pop；
    // 若本页仍存活，则关闭它以免残留。
    if (context.mounted) {
      Navigator.of(context).maybePop();
    }
  }
}

enum _AccountAction { switch_, edit, delete }
