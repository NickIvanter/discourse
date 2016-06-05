import TopicNavigation from '../components/topic-navigation';
import { h } from 'virtual-dom';
import { queryRegistry } from 'discourse/widgets/widget';

var postArticleWidget = queryRegistry('post-article');
var postBodyWidget = queryRegistry('post-body');

TopicNavigation.reopen({
  _checkSize() {
    this.set('info', { null, null });
  }
});

if (postArticleWidget) {
  postArticleWidget.prototype.html = function (attrs, state) {
    const rows = [h('a.tabLoc', { attributes: { href: ''} })];
    if (state.repliesAbove.length) {
      const replies = state.repliesAbove.map(p => this.attach('embedded-post', p, { state: { above: true } }));
      rows.push(h('div.row', h('section.embedded-posts.top.topic-body.offset2', replies)));
    }

    rows.push(h('div.row', [this.attach('post-avatar', attrs),
                            this.attach('post-body', attrs),
                            this.attach('post-gutter', attrs)]));
    return rows;
  };
}

if (postBodyWidget) {
  postBodyWidget.prototype.html = function (attrs) {
    const postContents = this.attach('post-contents', attrs);
    const result = [this.attach('post-meta-data', attrs), postContents];

    result.push(this.attach('actions-summary', attrs));
    if (attrs.showTopicMap) {
      result.push(this.attach('topic-map', attrs));
    }

    return result;
  };
}
