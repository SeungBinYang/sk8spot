import 'dart:async';

import 'package:flutter/material.dart';

import 'spot.dart';

/// 지명 검색은 스팟 조회와 분리한다. 결과를 선택하면 지도 중심만 이동한다.
Future<PlaceResult?> showPlaceSearch(BuildContext context) {
  return showModalBottomSheet<PlaceResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(ctx).height * 0.65,
        child: const _PlaceSearchSheet(),
      ),
    ),
  );
}

class _PlaceSearchSheet extends StatefulWidget {
  const _PlaceSearchSheet();

  @override
  State<_PlaceSearchSheet> createState() => _PlaceSearchSheetState();
}

class _PlaceSearchSheetState extends State<_PlaceSearchSheet> {
  final _input = TextEditingController();
  Timer? _debounce;
  int _requestId = 0;
  bool _loading = false;
  bool _failed = false;
  List<PlaceResult> _results = const [];

  @override
  void dispose() {
    _debounce?.cancel();
    _input.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    final requestId = ++_requestId;
    final query = value.trim();
    setState(() {
      _results = const [];
      _loading = query.length >= 2;
      _failed = false;
    });
    if (query.length < 2) return;
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        final results = await SpotRepo.searchPlace(query);
        if (!mounted || requestId != _requestId) return;
        setState(() {
          _results = results;
          _loading = false;
        });
      } catch (_) {
        if (!mounted || requestId != _requestId) return;
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: TextField(
            controller: _input,
            autofocus: true,
            onChanged: _onChanged,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: '어디로 이동할까요? 예: 홍대, 여의도',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: _failed
              ? const Center(child: Text('지명을 검색하지 못했어요. 다시 입력해 주세요'))
              : !_loading && _input.text.trim().length >= 2 && _results.isEmpty
              ? const Center(child: Text('검색 결과가 없어요'))
              : ListView.builder(
                  itemCount: _results.length,
                  itemBuilder: (context, index) {
                    final place = _results[index];
                    return ListTile(
                      title: Text(place.name),
                      subtitle: Text(place.address),
                      onTap: () => Navigator.pop(context, place),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}
