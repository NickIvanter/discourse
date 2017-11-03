import DiscourseRoute from 'discourse/routes/discourse';

export default DiscourseRoute.extend({

  model() {
    return this.store.find('queuedPost', {
      //status: "new",
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
