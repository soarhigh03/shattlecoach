import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../routing/app_router.dart';
import '../../services/onboarding_service.dart';
import '../../services/profile_service.dart';

enum DominantHand { right, left }

class ProfileDraft {
  ProfileDraft({this.displayName = '', this.hand = DominantHand.right});

  String displayName;
  DominantHand hand;
}

/// Held in-memory during onboarding. After submit the profile is persisted to
/// Supabase by the auth controller (TODO: wire when DB schema is finalized).
final profileDraftProvider = StateProvider<ProfileDraft>((_) => ProfileDraft());

class ProfileSetupPage extends ConsumerStatefulWidget {
  const ProfileSetupPage({super.key});

  @override
  ConsumerState<ProfileSetupPage> createState() => _ProfileSetupPageState();
}

class _ProfileSetupPageState extends ConsumerState<ProfileSetupPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: ref.read(profileDraftProvider).displayName);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _finishing = true);
    final draft = ref.read(profileDraftProvider);
    draft.displayName = _name.text.trim();
    try {
      await ref.read(profileServiceProvider).completeOnboarding(
            name: draft.displayName,
            handedness: draft.hand == DominantHand.left ? 'left' : 'right',
          );
    } catch (e) {
      if (!mounted) return;
      setState(() => _finishing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('프로필 저장에 실패했어요: $e')),
      );
      return;
    }
    await ref.read(onboardingServiceProvider).markCompleted();
    ref.invalidate(onboardingCompletedProvider);
    ref.invalidate(myProfileProvider);
    if (!mounted) return;
    context.go(AppRoute.aiCoach);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const _Header(),
          Expanded(
            child: DecoratedBox(
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(
                  top: BorderSide(color: Colors.black, width: 2),
                ),
              ),
              child: SafeArea(
                top: false,
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text(
                                '진행하기 위해 몇 가지 정보가 필요해.',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 28),
                              const _RequiredLabel(label: '이름'),
                              const SizedBox(height: 8),
                              TextFormField(
                                controller: _name,
                                decoration: const InputDecoration(),
                                textInputAction: TextInputAction.done,
                                validator: (v) =>
                                    (v == null || v.trim().isEmpty)
                                        ? '이름을 입력해 주세요'
                                        : null,
                              ),
                              const SizedBox(height: 24),
                              const _RequiredLabel(label: '주 사용 손'),
                              const SizedBox(height: 8),
                              _HandSelector(
                                value: ref.watch(profileDraftProvider).hand,
                                onChanged: (h) => ref
                                    .read(profileDraftProvider.notifier)
                                    .update(
                                      (d) => ProfileDraft(
                                        displayName: d.displayName,
                                        hand: h,
                                      ),
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                        child: _StartButton(
                          busy: _finishing,
                          onPressed: _submit,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 400,
      width: double.infinity,
      child: ClipRect(
        child: Stack(
          children: [
            Positioned.fill(
              child: Image.asset('assets/images/bg.png', fit: BoxFit.cover),
            ),
            Positioned(
              top: 20,
              left: 0,
              child: Transform.flip(
                flipX: true,
                child: Image.asset(
                  'assets/images/coach_full.png',
                  width: 320,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RequiredLabel extends StatelessWidget {
  const _RequiredLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: label,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const TextSpan(
            text: ' *',
            style: TextStyle(color: Color(0xFFE91E63), fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _HandSelector extends StatelessWidget {
  const _HandSelector({required this.value, required this.onChanged});
  final DominantHand value;
  final ValueChanged<DominantHand> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<DominantHand>(
      segments: const [
        ButtonSegment(value: DominantHand.right, label: Text('오른손')),
        ButtonSegment(value: DominantHand.left, label: Text('왼손')),
      ],
      selected: {value},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}

class _StartButton extends StatelessWidget {
  const _StartButton({required this.busy, required this.onPressed});
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: Material(
        color: Colors.black,
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: busy ? null : onPressed,
          child: Center(
            child: busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    '샤틀코치 시작하기',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
