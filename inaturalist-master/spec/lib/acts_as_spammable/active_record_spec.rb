require "spec_helper"

describe "ActsAsSpammable", "ActiveRecord" do

  before(:all) do
    User.destroy_all
    @user = User.make!
    Rakismet.disabled = false
  end

  after(:all) do
    Rakismet.disabled = true
  end

  it "recognizes spam" do
    expect(Rakismet).to receive(:akismet_call).and_return("true")
    o = Observation.make!(user: @user)
    expect(o.spam?).to be true
  end

  it "recognizes non-spam" do
    o = Observation.make!(user: @user)
    expect(o.spam?).to be false
  end

  it "knows when things have been flagged as spam" do
    o = Observation.make!(user: @user)
    expect(o.flagged_as_spam?).to be false
    Flag.make!(flaggable: o, flag: Flag::SPAM)
    expect(o.flagged_as_spam?).to be true
    expect(Observation.flagged_as_spam.first.id).to be o.id
  end

  it "knows when things have been flagged as spam when flags have been preloaded" do
    o = Observation.make!(user: @user)
    Flag.make!(flaggable: o, flag: Flag::SPAM)
    o = Observation.where(id: o).includes(:flags).first
    expect(o.flagged_as_spam?).to be true
  end

  it "knows when thing have not been flagged as spam" do
    o = Observation.make!(user: @user)
    expect(Observation.not_flagged_as_spam.first.id).to be o.id
  end

  it "resolved flags are not spam" do
    o = Observation.make!(user: @user)
    expect(o.flagged_as_spam?).to be false
    f = Flag.make!(flaggable: o, flag: Flag::SPAM)
    expect(o.flagged_as_spam?).to be true
    Flag.last.update_attributes(resolved: true, resolver: @user)
    expect(o.flagged_as_spam?).to be false
  end

  it "does not check for spam unless a spammable field is modified" do
    expect(Rakismet).to receive(:akismet_call).and_return("true")
    g = Guide.make!(user: @user, title: "   ", description: nil)
    expect(g.flagged_as_spam?).to be false
    # we now set the user, which would normally cause an item to be flagged
    # as spam by akismet. But since user isn't one of the text fields which
    # we send to akismet, and none of those fields were changed, the spam
    # check isn't triggered yet
    g.updated_at = Time.now
    g.save
    expect(g.flagged_as_spam?).to be false
    g.reload
    # and now we set one of the configured fields and the spam check is
    # triggered. Since we set the spammy user above the check will fail
    # and create a spam flag
    g.description = "anything"
    g.save
    expect(g.flagged_as_spam?).to be true
  end

  it "does not check for spam all fields are blank" do
    o = Observation.make!(user: @user)
    o.description = ""
    expect(o).to_not receive(:spam?)
    o.save
    expect(o.flagged_as_spam?).to be false
  end

  it "creates a spam flag when the akismet check fails" do
    expect(Rakismet).to receive(:akismet_call).once.ordered.and_return("true")
    g = Guide.make!(user: @user, title: "   ", description: nil)
    expect(g.flagged_as_spam?).to be false
    g.description = "spam"
    g.save
    expect(g.flagged_as_spam?).to be true
  end

  it "ultimately updates the users spam count" do
    starting_spam_count = @user.spam_count
    expect(Rakismet).to receive(:akismet_call).once.ordered.and_return("true")
    g = Guide.make!(user: @user)
    @user.reload
    expect(@user.spam_count).to be (starting_spam_count + 1)
  end

  it "knows which models are spammable" do
    expect( Observation.spammable? ).to be true
    expect( Post.spammable? ).to be true
    expect( User.spammable? ).to be true
    expect( Photo.spammable? ).to be false
    expect( Site.spammable? ).to be false
    expect( Taxon.spammable? ).to be false
  end

  it "identifies flagged content as known_spam?" do
    o = Observation.make!(user: @user)
    expect(o.known_spam?).to be false
    Flag.make!(flaggable: o, flag: Flag::SPAM, user: @user)
    o.reload
    expect(o.known_spam?).to be true
  end

  it "identifies guide taxa as not spam if its sections aren't spam" do
    gt = GuideTaxon.make!
    section = GuideSection.make!(guide_taxon: gt)
    expect(gt.known_spam?).to be false
  end

  it "identifies guide taxa as known_spam? if its sections are spam" do
    gt = GuideTaxon.make!
    section = GuideSection.make!(guide_taxon: gt)
    Flag.make!(flaggable: section, flag: Flag::SPAM)
    gt.reload
    expect(gt.known_spam?).to be true
  end

  it "identifies spammer-owned content as owned_by_spammer?" do
    u = User.make!
    o = Observation.make!(user: u)
    expect(o.owned_by_spammer?).to be false
    u.update_column(:spammer, true)
    o.reload
    expect(o.owned_by_spammer?).to be true
  end

  it "users are spam if they are spammers" do
    u = User.make!
    expect(u.owned_by_spammer?).to be false
    u.update_column(:spammer, true)
    u.reload
    expect(u.owned_by_spammer?).to be true
  end

  it "all models respond to known_spam?" do
    expect(Role.make!.known_spam?).to be false
    expect(Taxon.make!.known_spam?).to be false
  end

  it "all models respond to spam_or_owned_by_spammer?" do
    expect(Role.make!.owned_by_spammer?).to be false
    expect(Taxon.make!.owned_by_spammer?).to be false
  end

  it "does not allow spammers to create objects" do
    u = User.make!
    expect{ Comment.make!(user: u) }.to_not raise_error
    u.update_column(:spammer, true)
    expect{ Comment.make!(user: u) }.to raise_error(ActiveRecord::RecordInvalid,
      "Validation failed: User cannot be spammer")
  end


  describe "User Exceptions" do
    it "checks users for spam when they have descriptions" do
      u = User.make!
      expect(Rakismet).to receive(:akismet_call)
      User.make!(description: "anything")
    end

    it "does not check user life lists that have default values" do
      u = User.make!
      expect(Rakismet).to_not receive(:akismet_call)
      LifeList.make!(user: u, title: nil, description: nil)
    end

    it "does not users with no description" do
      u = User.make!
      expect(Rakismet).to_not receive(:akismet_call)
      User.make!(description: nil)
    end

    it "knows when LifeLists have default values" do
      expect(LifeList.make!(title: nil, description: nil).
        default_life_list?).to be true
      expect( LifeList.make!(title: "Anything", description: nil).
        default_life_list?).to be false
    end
  end

  describe "not_flagged_as_spam" do    
    it "includes records not flagged as spam" do
      o = Observation.make!
      expect( o ).not_to be_known_spam
      expect( o.user ).not_to be_spammer
      expect( Observation.all ).to include o
      expect( Observation.not_flagged_as_spam ).to include o
    end

    it "includes records by users with unknown spammer status" do
      u = User.make!
      expect( u.spammer ).to be_nil
      o = Observation.make!(user: u)
      expect( o ).not_to be_known_spam
      expect( Observation.not_flagged_as_spam ).to include o
    end

    it "excludes records flagged as spam" do
      o = Observation.make!(user: @user)
      Flag.make!(flaggable: o, flag: Flag::SPAM)
      expect( o ).to be_known_spam
      expect( o.user ).not_to be_spammer
      expect( Observation.not_flagged_as_spam ).not_to include o
    end

    it "excludes records not flagged as spam by spammers" do
      o = Observation.make!
      o.user.update_attribute(:spammer, true)
      expect( o.user ).to be_spammer
      expect( Observation.not_flagged_as_spam ).not_to include o
    end
  end
end
