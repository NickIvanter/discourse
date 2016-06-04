import TopicNavigation from '../components/topic-navigation';

TopicNavigation.reopen({
  _checkSize() {
    this.set('info', { null, null });
  }
});
