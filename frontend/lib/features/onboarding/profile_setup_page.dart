import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../routing/app_router.dart';

enum ClubRole { member, exec }

enum DominantHand { right, left }

class ProfileDraft {
  ProfileDraft({
    this.displayName = '',
    this.role = ClubRole.member,
    this.hand = DominantHand.right,
    this.monthsExperience = 0,
  });

  String displayName;
  ClubRole role;
  DominantHand hand;
  int monthsExperience;
}

/// Held in-memory during onboarding. After the permissions step, the profile
/// is persisted to Supabase by the auth controller (TODO: wire when DB schema
/// is finalized).
final profileDraftProvider = StateProvider<ProfileDraft>((_) => ProfileDraft());

class ProfileSetupPage extends ConsumerStatefulWidget {
  const ProfileSetupPage({super.key});

  @override
  ConsumerState<ProfileSetupPage> createState() => _ProfileSetupPageState();
}

class _ProfileSetupPageState extends ConsumerState<ProfileSetupPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _months;

  @override
  void initState() {
    super.initState();
    final draft = ref.read(profileDraftProvider);
    _name = TextEditingController(text: draft.displayName);
    _months = TextEditingController(
      text: draft.monthsExperience == 0 ? '' : draft.monthsExperience.toString(),
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _months.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final draft = ref.read(profileDraftProvider);
    draft.displayName = _name.text.trim();
    draft.monthsExperience = int.tryParse(_months.text.trim()) ?? 0;
    context.go(AppRoute.onboardingPermissions);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final draft = ref.watch(profileDraftProvider);

    return Form(
      key: _formKey,
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '프로필 설정',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '동아리 내에서 표시될 정보예요.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _name,
                    decoration: const InputDecoration(
                      labelText: '이름 / 닉네임',
                      hintText: '예: 최은우',
                    ),
                    textInputAction: TextInputAction.next,
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? '이름을 입력해 주세요'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  _SectionLabel(label: '동아리 역할'),
                  const SizedBox(height: 8),
                  SegmentedButton<ClubRole>(
                    segments: const [
                      ButtonSegment(value: ClubRole.member, label: Text('일반 부원')),
                      ButtonSegment(value: ClubRole.exec, label: Text('운영진')),
                    ],
                    selected: {draft.role},
                    onSelectionChanged: (s) {
                      ref.read(profileDraftProvider.notifier).update((d) =>
                          ProfileDraft(
                            displayName: d.displayName,
                            role: s.first,
                            hand: d.hand,
                            monthsExperience: d.monthsExperience,
                          ));
                    },
                  ),
                  const SizedBox(height: 20),
                  _SectionLabel(label: '주 사용 손'),
                  const SizedBox(height: 8),
                  SegmentedButton<DominantHand>(
                    segments: const [
                      ButtonSegment(value: DominantHand.right, label: Text('오른손')),
                      ButtonSegment(value: DominantHand.left, label: Text('왼손')),
                    ],
                    selected: {draft.hand},
                    onSelectionChanged: (s) {
                      ref.read(profileDraftProvider.notifier).update((d) =>
                          ProfileDraft(
                            displayName: d.displayName,
                            role: d.role,
                            hand: s.first,
                            monthsExperience: d.monthsExperience,
                          ));
                    },
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: _months,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '배드민턴 구력 (개월)',
                      hintText: '예: 6',
                      suffixText: '개월',
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return null;
                      final n = int.tryParse(v.trim());
                      if (n == null || n < 0) return '0 이상의 숫자를 입력해 주세요';
                      return null;
                    },
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _submit,
                child: const Text('다음'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
    );
  }
}
