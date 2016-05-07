export default Ember.Controller.extend({
  queryParams: ['state', 'limit', 'dateFrom', 'dateTo'],
  state: 'new',
  limit: 100,
  dateFrom: null,
  dateTo: null,

  isNewList: Ember.computed.equal('state', 'new'),
  isApprovedList: Ember.computed.equal('state', 'approved'),
  isRejectedList: Ember.computed.equal('state', 'rejected'),

  showApproveButton: Ember.computed('state', function() {
    return this.state=='new' || this.state=='rejected';
  }),
  showRejectButton: Ember.computed('state', function() {
    return this.state=='new';
  }),
  showEditButton: Ember.computed('state', function() {
    return this.state=='new' || this.state=='rejected';
  })
});
