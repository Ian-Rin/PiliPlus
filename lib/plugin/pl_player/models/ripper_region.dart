/// Which CDN nodes the thread-ripper proxy takes ([Pref.threadRipperRegion]).
enum RipperRegion {
  /// Upstream's default: every file is there, threads make up the speed.
  mainland('大陆', '只用大陆节点：冷门视频也有，海外看靠多线程补速度'),

  /// Fast from abroad for popular videos; rare ones are often not cached.
  overseas('海外', '只用海外节点：热门视频快，冷门视频常没缓存'),

  /// This fork's: a start (first bytes, first window) races overseas and
  /// mainland nodes, the rest comes from the mainland's.
  auto('自动', '起播和跳转时海外、大陆节点一起抢，谁快用谁；之后用大陆节点继续');

  const RipperRegion(this.label, this.description);
  final String label;
  final String description;
}
