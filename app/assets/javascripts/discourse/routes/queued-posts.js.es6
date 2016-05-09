import loadScript from 'discourse/lib/load-script';
import DiscourseRoute from 'discourse/routes/discourse';

export default DiscourseRoute.extend({

  // this route requires the sanitizer
  beforeModel() {
    loadScript('defer/html-sanitizer-bundle');
  },

  model(params) {
    return this.store.find('queuedPost', {
      state: params.state,
      limit: params.limit,
      dateFrom: params.dateFrom,
      dateTo: params.dateTo
    });
  },

  actions: {
    removePost(post) {
      this.modelFor('queued-posts').removeObject(post);
    },

    refresh() {
      this.modelFor('queued-posts').refresh();
    }
  },

  queryParams: {
    state: {
      refreshModel: true
    },
    dateFrom: {
      refreshModel: true
    },
    dateTo: {
      refreshModel: true
    }
  },

});
