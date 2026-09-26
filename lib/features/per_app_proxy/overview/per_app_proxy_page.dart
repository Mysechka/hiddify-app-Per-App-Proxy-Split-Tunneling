import 'package:dartx/dartx.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/region.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/per_app_proxy/data/desktop_installed_apps_service.dart';
import 'package:hiddify/features/per_app_proxy/data/windows_installed_apps_service.dart';
import 'package:hiddify/features/per_app_proxy/model/app_package_info.dart';
import 'package:hiddify/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:hiddify/features/per_app_proxy/model/pkg_flag.dart';
import 'package:hiddify/features/per_app_proxy/overview/per_app_proxy_loading_notifier.dart';
import 'package:hiddify/features/per_app_proxy/overview/per_app_proxy_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:installed_apps/index.dart';

class PerAppProxyPage extends HookConsumerWidget with PresLogger {
  const PerAppProxyPage({super.key});

  int _getPriority(AppPackageInfo app, Map<String, int> selected) {
    final flag = selected[app.packageName];
    if (flag == null) return 4;
    if (PkgFlag.userSelection.check(flag)) {
      return 1;
    } else if (PkgFlag.autoSelection.check(flag) && !PkgFlag.forceDeselection.check(flag)) {
      return 2;
    } else {
      return 3;
    }
  }

  Future<Set<AppPackageInfo>> getApps(bool hideSystem) async {
    if (PlatformUtils.isWindows) {
      return (await WindowsInstalledAppsService.getInstalledApps(hideSystem: hideSystem)).toSet();
    }
    if (PlatformUtils.isDesktop) {
      return await DesktopInstalledAppsService.getInstalledApps(hideSystem: hideSystem);
    }
    if (!PlatformUtils.isAndroid) return {};
    return (await InstalledApps.getInstalledApps(
      hideSystem,
      true,
    )).map((e) => AppPackageInfo(packageName: e.packageName, name: e.name, icon: e.icon)).toSet();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = ref.watch(translationsProvider).requireValue;
    final localizations = MaterialLocalizations.of(context);

    final currentPerAppMode = ref.watch(Preferences.perAppProxyMode);
    final mode = currentPerAppMode.toAppProxy();
    final selectedApps = ref.watch(PerAppProxyProvider(mode));

    final hideSystemApps = useState(false);
    final filterOnlySelected = useState(false);
    final isSearching = useState(false);
    final searchQuery = useState("");
    final searchController = useTextEditingController();
    final sortListener = useState(false);

    final asyncFilteredApps = useFuture(useMemoized(() => getApps(hideSystemApps.value), [hideSystemApps.value]));

    final totalFoundCount = asyncFilteredApps.hasData ? asyncFilteredApps.requireData.length : 0;
    final selectedCount = (selectedApps.hasValue && selectedApps is AsyncData)
        ? selectedApps.requireValue.entries.where((e) => !PkgFlag.forceDeselection.check(e.value)).length
        : 0;

    final displayedApps = useMemoized<AsyncValue<List<AppPackageInfo>>>(
      () {
        if (!(selectedApps.hasValue &&
            selectedApps is AsyncData &&
            asyncFilteredApps.hasData &&
            asyncFilteredApps.connectionState == ConnectionState.done)) {
          return const AsyncValue.loading();
        }
        var appsList = asyncFilteredApps.requireData.toList();

        if (filterOnlySelected.value) {
          appsList = appsList.where((app) {
            final flag = selectedApps.requireValue[app.packageName];
            return flag != null && !PkgFlag.forceDeselection.check(flag);
          }).toList();
        }

        if (searchQuery.value.isNotBlank) {
          appsList = appsList
              .where((e) =>
                  e.name.toLowerCase().contains(searchQuery.value.toLowerCase()) ||
                  e.packageName.toLowerCase().contains(searchQuery.value.toLowerCase()))
              .toList();
          return AsyncValue.data(appsList);
        }

        appsList.sort((a, b) {
          final priorityA = _getPriority(a, selectedApps.requireValue);
          final priorityB = _getPriority(b, selectedApps.requireValue);
          return priorityA.compareTo(priorityB);
        });
        return AsyncValue.data(appsList);
      },
      [
        asyncFilteredApps.connectionState == ConnectionState.done,
        hideSystemApps.value,
        filterOnlySelected.value,
        selectedApps.hasValue,
        searchQuery.value,
        sortListener.value,
      ],
    );

    if (mode != null) {
      ref.listen(PerAppProxyProvider(mode), (previous, next) {
        if (previous != null) {
          if ((previous, next) case (AsyncData(value: final prevData), AsyncData(value: final nextData))) {
            if (nextData.isNotEmpty) {
              if ((nextData.length - prevData.length).abs() > 1) sortListener.value = !sortListener.value;
            }
          }
        }
      });
    }

    final scrollController = useScrollController();
    const double scrollThreshold = 300.0;
    final showScrollToTop = useState<bool>(false);
    useEffect(() {
      void listener() {
        showScrollToTop.value = scrollController.offset > scrollThreshold;
      }

      scrollController.addListener(listener);
      return () => scrollController.removeListener(listener);
    }, []);
    useEffect(() {
      showScrollToTop.value = false;
      return null;
    }, [displayedApps]);

    return Scaffold(
      appBar: isSearching.value
          ? AppBar(
              title: TextField(
                controller: searchController,
                onChanged: (value) => searchQuery.value = value,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: "${localizations.searchFieldLabel}...",
                  isDense: true,
                  filled: false,
                  border: InputBorder.none,
                  suffixIcon: searchQuery.value.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear_rounded),
                          onPressed: () {
                            searchController.clear();
                            searchQuery.value = "";
                          },
                        )
                      : null,
                ),
              ),
              leading: IconButton(
                onPressed: () {
                  searchController.clear();
                  searchQuery.value = "";
                  isSearching.value = false;
                },
                icon: const Icon(Icons.arrow_back_rounded),
                tooltip: localizations.cancelButtonLabel,
              ),
            )
          : AppBar(
              title: Text(t.pages.settings.routing.generalOptions.perAppProxy.title),
              actions: [
                IconButton(
                  icon: const Icon(FluentIcons.search_24_regular),
                  onPressed: () => isSearching.value = true,
                  tooltip: localizations.searchFieldLabel,
                ),
                MenuAnchor(
                  menuChildren: <Widget>[
                    SubmenuButton(
                      menuChildren: <Widget>[
                        MenuItemButton(
                          child: Text(t.pages.settings.routing.generalOptions.perAppProxy.options.import.clipboard),
                          onPressed: () async => await ref
                              .read(dialogNotifierProvider.notifier)
                              .showConfirmation(
                                title: t.common.msg.import.confirm,
                                message: t.dialogs.confirmation.perAppProxy.import.msg,
                              )
                              .then((shouldImport) async {
                                if (shouldImport) await ref.read(PerAppProxyProvider(mode).notifier).importClipboard();
                              }),
                        ),
                        MenuItemButton(
                          child: Text(t.pages.settings.routing.generalOptions.perAppProxy.options.import.file),
                          onPressed: () async => await ref
                              .read(dialogNotifierProvider.notifier)
                              .showConfirmation(
                                title: t.pages.settings.routing.generalOptions.perAppProxy.options.import.file,
                                message: t.pages.settings.routing.generalOptions.perAppProxy.options.import.msg,
                              )
                              .then((shouldImport) async {
                                if (shouldImport) await ref.read(PerAppProxyProvider(mode).notifier).importFile();
                              }),
                        ),
                      ],
                      child: Text(t.common.import),
                    ),
                    SubmenuButton(
                      menuChildren: <Widget>[
                        MenuItemButton(
                          child: Text(t.pages.settings.routing.generalOptions.perAppProxy.options.export.clipboard),
                          onPressed: () async => await ref.read(PerAppProxyProvider(mode).notifier).exportClipboard(),
                        ),
                        MenuItemButton(
                          child: Text(t.pages.settings.routing.generalOptions.perAppProxy.options.export.file),
                          onPressed: () async => await ref.read(PerAppProxyProvider(mode).notifier).exportFile(),
                        ),
                      ],
                      child: Text(t.common.export),
                    ),
                    if (ref.watch(ConfigOptions.region) != Region.other)
                      MenuItemButton(
                        child: Text(t.pages.settings.routing.generalOptions.perAppProxy.options.shareToAll),
                        onPressed: () async => await ref
                            .read(appProxyLoadingProvider.notifier)
                            .doAsync(ref.read(PerAppProxyProvider(mode).notifier).shareOnGithub),
                      ),
                    const PopupMenuDivider(),
                    MenuItemButton(
                      child: Text(t.pages.settings.routing.generalOptions.perAppProxy.options.clearAllSelections),
                      onPressed: () => ref.read(PerAppProxyProvider(mode).notifier).clearAll(),
                    ),
                  ],
                  builder: (context, controller, child) => AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: ref.watch(appProxyLoadingProvider)
                        ? const Padding(
                            padding: EdgeInsets.all(8),
                            child: SizedBox(width: 32, height: 32, child: CircularProgressIndicator()),
                          )
                        : IconButton(
                            onPressed: () {
                              if (controller.isOpen) {
                                controller.close();
                              } else {
                                controller.open();
                              }
                            },
                            icon: const Icon(Icons.more_vert_rounded),
                          ),
                  ),
                ),
              ],
            ),
      floatingActionButton: showScrollToTop.value
          ? FloatingActionButton(
              onPressed: () =>
                  scrollController.animateTo(0.0, duration: const Duration(milliseconds: 500), curve: Curves.easeOut),
              child: const Icon(Icons.keyboard_arrow_up_rounded),
            )
          : (PlatformUtils.isWindows || PlatformUtils.isDesktop)
              ? FloatingActionButton.extended(
                  onPressed: () async {
                    if (PlatformUtils.isWindows) {
                      final result = await FilePicker.platform.pickFiles(
                        type: FileType.custom,
                        allowedExtensions: ['exe'],
                        dialogTitle: 'Select .exe file',
                      );
                      if (result != null && result.files.single.path != null && mode != null) {
                        final exePath = result.files.single.path!;
                        final appInfo = WindowsInstalledAppsService.appInfoForExePath(exePath);
                        await ref.read(PerAppProxyProvider(mode).notifier).updatePkg(appInfo.packageName);
                      }
                    } else {
                      final result = await FilePicker.platform.pickFiles(
                        dialogTitle: 'Select Application',
                      );
                      if (result != null && result.files.single.path != null && mode != null) {
                        final appPath = result.files.single.path!;
                        final appInfo = DesktopInstalledAppsService.appInfoForPath(appPath);
                        await ref.read(PerAppProxyProvider(mode).notifier).updatePkg(appInfo.packageName);
                      }
                    }
                  },
                  label: Text(PlatformUtils.isWindows ? 'Add .exe' : 'Add App'),
                  icon: const Icon(Icons.add_circle_outline_rounded),
                )
              : (PlatformUtils.isAndroid && ref.watch(ConfigOptions.region) != Region.other)
                  ? FloatingActionButton.extended(
                      onPressed: () async =>
                          await ref.read(bottomSheetsNotifierProvider.notifier).showAutoAppsSelection(mode: mode!),
                      label: Text(t.pages.settings.routing.generalOptions.perAppProxy.autoSelection.title),
                      icon: Icon(
                        ref.watch(Preferences.autoAppsSelectionRegion) == null
                            ? Icons.toggle_off_outlined
                            : Icons.toggle_on_rounded,
                      ),
                    )
                  : null,
      body: Column(
        children: [
          // Mode Switcher Banner & Quick Controls
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: theme.colorScheme.outlineVariant.withOpacity(0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: SegmentedButton<PerAppProxyMode>(
                    segments: [
                      ButtonSegment(
                        value: PerAppProxyMode.exclude,
                        label: Text(t.pages.settings.routing.generalOptions.perAppProxy.modes.bypass),
                        icon: const Icon(Icons.call_split_rounded, size: 18),
                      ),
                      ButtonSegment(
                        value: PerAppProxyMode.include,
                        label: Text(t.pages.settings.routing.generalOptions.perAppProxy.modes.proxy),
                        icon: const Icon(Icons.shield_outlined, size: 18),
                      ),
                      ButtonSegment(
                        value: PerAppProxyMode.off,
                        label: Text(t.pages.settings.routing.generalOptions.perAppProxy.modes.all),
                        icon: const Icon(Icons.power_settings_new_rounded, size: 18),
                      ),
                    ],
                    selected: {currentPerAppMode},
                    onSelectionChanged: (newSelection) async {
                      final selected = newSelection.first;
                      if (ref.read(Preferences.autoAppsSelectionRegion) != null) {
                        await ref.read(PerAppProxyProvider(mode).notifier).clearAutoSelected();
                      }
                      if (selected == PerAppProxyMode.off && context.mounted) {
                        await ref.read(Preferences.perAppProxyMode.notifier).update(selected);
                        if (context.mounted) context.pop();
                        return;
                      }
                      await ref.read(Preferences.perAppProxyMode.notifier).update(selected);
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 15,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const Gap(6),
                      Expanded(
                        child: Text(
                          currentPerAppMode.present(t).message,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '$selectedCount / $totalFoundCount',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Gap(8),
                // Filter Chips Row
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    children: [
                      FilterChip(
                        label: Text('Все ($totalFoundCount)'),
                        selected: !filterOnlySelected.value,
                        onSelected: (_) => filterOnlySelected.value = false,
                        showCheckmark: false,
                      ),
                      const Gap(8),
                      FilterChip(
                        label: Text('Выбранные ($selectedCount)'),
                        selected: filterOnlySelected.value,
                        onSelected: (_) => filterOnlySelected.value = true,
                        showCheckmark: true,
                      ),
                      const Gap(8),
                      FilterChip(
                        label: Text(t.pages.settings.routing.generalOptions.perAppProxy.hideSysApps),
                        selected: hideSystemApps.value,
                        onSelected: (val) => hideSystemApps.value = val,
                        showCheckmark: true,
                      ),
                    ],
                  ),
                ),
                const Gap(4),
              ],
            ),
          ),
          // App List
          Expanded(
            child: displayedApps.when(
              data: (packages) {
                if (packages.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            isSearching.value ? FluentIcons.search_24_regular : Icons.apps_outlined,
                            size: 48,
                            color: theme.colorScheme.outline,
                          ),
                          const Gap(12),
                          Text(
                            isSearching.value
                                ? 'Приложения по запросу "${searchQuery.value}" не найдены'
                                : filterOnlySelected.value
                                    ? 'Нет выбранных приложений'
                                    : 'Список приложений пуст',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                          if (isSearching.value || filterOnlySelected.value) ...[
                            const Gap(12),
                            OutlinedButton.icon(
                              onPressed: () {
                                searchController.clear();
                                searchQuery.value = "";
                                filterOnlySelected.value = false;
                              },
                              icon: const Icon(Icons.refresh_rounded, size: 18),
                              label: const Text('Сбросить фильтры'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: 88),
                  controller: scrollController,
                  itemBuilder: (context, index) {
                    final package = packages[index];
                    final flag = selectedApps.requireValue[package.packageName];
                    final isChecked = flag != null && PkgFlag.checkboxValue(flag) == true;
                    return CheckboxListTile.adaptive(
                      title: Row(
                        children: [
                          Flexible(
                            child: Text(
                              package.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: isChecked ? FontWeight.w600 : FontWeight.normal,
                              ),
                            ),
                          ),
                          if (flag != null && PkgFlag.forceDeselection.check(flag)) ...[
                            const Gap(6),
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(color: theme.colorScheme.error, shape: BoxShape.circle),
                            ),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        package.packageName,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      value: flag == null ? false : PkgFlag.checkboxValue(flag),
                      tristate: true,
                      onChanged: (_) => ref.read(PerAppProxyProvider(mode).notifier).updatePkg(package.packageName),
                      secondary: package.icon == null
                          ? Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Icon(Icons.apps_rounded, size: 28),
                            )
                          : ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.memory(
                                package.icon!,
                                width: 44,
                                height: 44,
                                cacheWidth: 44,
                                cacheHeight: 44,
                                errorBuilder: (_, _, _) => Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Icon(Icons.apps_rounded, size: 28),
                                ),
                              ),
                            ),
                    );
                  },
                  itemCount: packages.length,
                );
              },
              error: (error, _) => SliverErrorBodyPlaceholder(error.toString()),
              loading: () => const Center(child: CircularProgressIndicator()),
            ),
          ),
        ],
      ),
    );
  }
}
