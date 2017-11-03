import ScrollTop from 'discourse/mixins/scroll-top';

export default Ember.View.extend(ScrollTop, {
  templateName: 'user/user',

  // Real name
  didInsertElement() {
    this._super();
    const swapContents = function($userName, $realName) {
      var $userNameContents = $userName.contents();
      var $realNameContents = $realName.contents();
      $userName.empty().append($realNameContents);
      $realName.empty().append($userNameContents);
    };
    Ember.run.scheduleOnce('afterRender', this, function() {
      var controller = this.get('controller');
      var user = controller.get('model');
      if (user.name) {
        var $primaryTextual = $('.primary-textual');
        var $h1 = $primaryTextual.children('h1').first();
        var $h2 = $primaryTextual.children('h2').first();
        swapContents($h1, $h2);
      }
    });
  }
});
