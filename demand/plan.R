generatePlans <- function(N, csv, endcsv, binCols, outdir, writeInterval) {
  # example inputs:
  # N<-10000 # generate 10k VISTA 2012-18 like daily plans
  # csv<-paste0('./setup/vista_2012_18_extracted_activities_weekday_time_bins.csv.gz')
  # binCols<-3:50 # specifies that columns 3-50 correspond to 48 time bins, i.e., 30-mins each
  # outdir<-"."
  # writeInterval <- 1000 # write to file every 1000 plans

  suppressPackageStartupMessages(library(dplyr))
  source("./util.R", local=TRUE)  

  getActivityGroups <- function(bins) {
    groups<-unique(bins$Activity.Group)
    groups<-groups[groups!="Mode Change" & groups !="With Someone"]
    return(groups)
  }
  
  createNewPlan <- function(bins, newbins, endbins, binCols) {
    
    getProbabilitiesMatrix <- function(bins, stat, binCols) {
      df<-bins
      df<-df[df$Activity.Group!="Mode Change" & df$Activity.Group!="With Someone",]
      df<-df[df$Activity.Stat==stat,]
      rnames<-df$Activity.Group
      cnames<-paste0("Bin",1:length(binCols))
      df<-as.matrix(df[,binCols])
      rownames(df)<-rnames
      colnames(df)<-cnames
      return(df)
    }  
    
    binsize<-length(binCols)
    binSizeInMins<-floor(60*24)/binsize
    binStartMins<-seq(0,binsize-1)*binSizeInMins
    binEndMins<-binStartMins+binSizeInMins-1
    
    groups<-getActivityGroups(bins)
    astp <- getProbabilitiesMatrix(bins, "Act.Start.Time.Prob", binCols)
    aetp <- getProbabilitiesMatrix(bins, "Act.End.Time.Prob", binCols)
    admm <- getProbabilitiesMatrix(bins, "Act.Duration.Mins.Mean", binCols)
    adms <- getProbabilitiesMatrix(bins, "Act.Duration.Mins.Sigma", binCols)
    
    nastp <- getProbabilitiesMatrix(newbins, "Act.Start.Time.Prob", binCols)
    naetp <- getProbabilitiesMatrix(newbins, "Act.End.Time.Prob", binCols)
    nadmm <- getProbabilitiesMatrix(newbins, "Act.Duration.Mins.Mean", binCols)
    nadms <- getProbabilitiesMatrix(newbins, "Act.Duration.Mins.Sigma", binCols)
    
    # normalise new-activity-start-time-probs (nastp) row-wise if non-zero
    xastp<-t(apply(nastp, 1, function(x) {
      if (sum(x==0)!=length(x)) {
        x/sum(x)
      } else {
        x
      }
    }))
    
    # get the difference from expected
    xastp<-(astp-xastp)
    xastp<-t(apply(xastp,1,function(x) {
      (x-min(x))
    }))
    xastp[astp==0]<-0
    # normalise new-activity-start-time-probs (nastp) row-wise if non-zero
    xastp<-t(apply(xastp, 1, function(x) {
      if (sum(x==0)!=length(x)) {
        x/sum(x)
      } else {
        x
      }
    }))
    
    plan<-data.frame(Activity=factor(levels=groups), StartBin=integer(), EndBin=integer())
    bin<-1
    while(bin<binsize) {
      prob<-sum(astp[,bin])/sum(astp) # proportion of activities that should start in this bin
      xprob<-ifelse(sum(nastp)==0, 0, sum(nastp[,bin])/sum(nastp)) # proportion of activities that did start in this bin
      # if we have more than our share of activities already start in this bin then progress to the next bin
      if(xprob>=prob) { bin<-bin+1; next }
      
      probs<-as.vector(xastp[,bin]) # pick the column probabilities
      filter<-probs==0 & astp[,bin]!=0 # find cols that are zero but shouldn't be and give them a small probability
      probs[filter]<- 0.001
      # if no activity can start in this bin then progress to the next bin
      if(sum(probs==0)==length(probs)) { bin<-bin+1; next }
      # if unlikely to start some activity in this bin then progress to the next bin
      #if(runif(1)<1-sum(probs)) { bin<-bin+1; next }
      # normalise if non-zero
      if (sum(probs==0)!=length(probs)) probs<-probs/sum(probs) 
      # pick a new activity for this bin
      act<-rownames(astp)[selectIndexFromProbabilities(probs)]
      # this will be the start bin for this activity  
      sbin<-bin 
      # pick duration for activity starting in this bin
      #mean<-admm[act,bin]; sigma<-adms[act,bin]
      #duration<-ifelse(mean==0||sigma==0, 
      #                 binSizeInMins, 
      #                 abs(round(rnorm(1,admm[act,bin],adms[act,bin]))) # WARNING: abs will change the distribution
      #)
      # pick an end bin for this activity (clipped to final bin)
      #ebin<-min(binsize, sbin + duration %/% binSizeInMins)
      
      ebins<-as.numeric(endbins[endbins$Act.Start.Bin==sbin & endbins$Activity.Group==act,binCols])
      if (sum(ebins==0)==length(ebins)) {
        # all probabilities are zero so make them equally non-zero for bins >= sbin 
        # therefore we will select randomly from them 
        ebins[sbin:length(ebins)]<-1
      }
      ebin<-selectIndexFromProbabilities(ebins)
      
      # save it
      plan[nrow(plan)+1,]<-list(act, sbin, ebin)
      # pick the next time bin
      bin<-ebin
    }
    
    # Sew up Home Morning/Night activities properly
    
    # First activity should always be Home, and starting in Bin1 
    #if(plan[1,]$Activity != "Home") {
    #  plan<-rbind(data.frame(Activity="Home", StartBin=c(1), EndBin=c(plan[1,]$StartBin)), plan)
    #}
    # If last activity is not Home, then make it so
    #if(plan[nrow(plan),]$Activity != "Home") {
    #  plan[nrow(plan)+1,]<-list("Home", plan[nrow(plan),]$EndBin, binsize)
    #}
    # If last activity is Home, then make sure it ends in the last bin
    #if(plan[nrow(plan),]$Activity == "Home" && plan[nrow(plan),]$EndBin != binsize) {
    #  plan[nrow(plan),]$EndBin<-binsize
    #}
    # Collapse blocks of same activity into one
    # see https://stackoverflow.com/questions/32529854/group-data-in-r-for-consecutive-rows
    plan <- plan %>%
      group_by(Activity, group_weight = cumsum(c(1, diff(rank(Activity)) != 0)), Activity) %>%
      summarise(StartBin=min(StartBin), EndBin=max(EndBin)) %>%
      arrange(group_weight) %>%
      select(-group_weight)
    
    return(as.data.frame(plan))
  }
  
  recordProgress <- function(plan, newbins, binCols) {
    binIndexOffset<-head(binCols,1)-1
    for(j in 1:nrow(plan)) {
      srow<-newbins$Activity.Group==plan[j,]$Activity & newbins$Activity.Stat=="Act.Start.Time.Prob"
      scol<-binIndexOffset+plan[j,]$StartBin
      erow<-newbins$Activity.Group==plan[j,]$Activity & newbins$Activity.Stat=="Act.End.Time.Prob"
      ecol<-binIndexOffset+plan[j,]$EndBin
      newbins[srow, scol]<-newbins[srow, scol] + 1
      newbins[erow, ecol]<-newbins[erow, ecol] + 1
    }
    return(newbins)
  }
  
  analysePlans<-function(bins, newbins, outdir) {
    # gather all the stats
    groups<-getActivityGroups(bins)
    stats<-c("Act.Start.Time.Prob", "Act.End.Time.Prob") #unique(bins$Activity.Stat)
    binsize<-length(binCols)
    binSizeInMins<-floor(60*24)/binsize
    pp<-data.frame(matrix(0, nrow = binsize*length(groups)*length(stats), ncol = 5))
    colnames(pp)<-c("Activity", "Stat", "Bin", "Expected", "Actual")
    rowid<-1
    for (act in groups) {
      for (stat in stats) {
        e<-as.numeric(bins[bins$Activity.Group==act & bins$Activity.Stat==stat,binCols])
        e<-e/sum(e)
        a<-as.numeric(newbins[newbins$Activity.Group==act & newbins$Activity.Stat==stat,binCols])
        a<-a/sum(a)
        shift<-(rowid-1)*binsize
        pp[shift+(1:binsize),"Activity"]<-rep(act,binsize)
        pp[shift+(1:binsize),"Stat"]<-rep(stat,binsize)
        pp[shift+(1:binsize),"Bin"]<-1:binsize
        pp[shift+(1:binsize),"Expected"]<-e
        pp[shift+(1:binsize),"Actual"]<-a
        rowid<-rowid+1
      }
    }
    qq<-data.frame(matrix(0, nrow = binsize*length(stats), ncol = 4))
    colnames(qq)<-c("Stat", "Bin", "Expected", "Actual")
    rowid<-1
    for (stat in stats) {
      e<-as.numeric(colSums(bins[bins$Activity.Stat==stat,binCols]))
      e<-e/sum(e)
      a<-as.numeric(colSums(newbins[newbins$Activity.Stat==stat,binCols]))
      a<-a/sum(a)
      shift<-(rowid-1)*binsize
      qq[shift+(1:binsize),"Stat"]<-rep(stat,binsize)
      qq[shift+(1:binsize),"Bin"]<-1:binsize
      qq[shift+(1:binsize),"Expected"]<-e
      qq[shift+(1:binsize),"Actual"]<-a
      rowid<-rowid+1
    }
    
    suppressMessages(library(reshape2))
    suppressMessages(library(ggplot2))
    
    outfile<-paste0(outdir,"/analysis-start-times-by-activity-qq.pdf")
    echo(paste0("Writing ", outfile, "\n"))
    gg<-ggplot(pp[pp$Stat=="Act.Start.Time.Prob",], aes(x=Expected, y=Actual)) + 
      geom_abline(aes(colour='red', slope = 1, intercept=0)) +
      geom_point(aes(fill=Bin), colour = 'blue', size=3, shape=21, alpha=0.9) + guides(colour=FALSE) +
      #theme(legend.position="none") + 
      theme(plot.title = element_text(hjust = 0.5)) +
      ggtitle(paste0('Activity Start Time Probabilities in ',binSizeInMins,'-Min Bins')) +
      facet_wrap(~Activity, scales="free", ncol=2)
    ggsave(outfile, gg, width=210, height=297, units = "mm")
    
    outfile<-paste0(outdir,"/analysis-end-times-by-activity-qq.pdf")
    echo(paste0("Writing ", outfile, "\n"))
    gg<-ggplot(pp[pp$Stat=="Act.End.Time.Prob",], aes(x=Expected, y=Actual)) + 
      geom_abline(aes(colour='red', slope = 1, intercept=0)) +
      geom_point(aes(fill=Bin), colour='blue', size=4, shape=21, alpha=0.9) + guides(colour=FALSE) +
      #theme(legend.position="none") + 
      theme(plot.title = element_text(hjust = 0.5)) +
      ggtitle(paste0('Activity End Time Probabilities in ',binSizeInMins,'-Min Bins')) +
      facet_wrap(~Activity, scales="free", ncol=2)
    ggsave(outfile, gg, width=210, height=297, units = "mm")
    
    outfile<-paste0(outdir,"/analysis-start-times-by-bin-qq.pdf")
    echo(paste0("Writing ", outfile, "\n"))
    gg<-ggplot(pp[pp$Stat=="Act.Start.Time.Prob",], aes(x=Expected, y=Actual)) + 
      geom_abline(aes(colour='red', slope = 1, intercept=0)) +
      geom_point(aes(fill=Activity, colour=Activity), size=2, shape=21, alpha=1)  +
      guides(colour=FALSE, fill=guide_legend(title="")) +
      theme(legend.position="bottom") + 
      theme(plot.title = element_text(hjust = 0.5), strip.background = element_blank(), strip.text.x = element_blank()) +
      ggtitle(paste0('Activity Start Time Probabilities in ',binSizeInMins,'-Min Bins')) +
      facet_wrap(~Bin, scales="free", ncol=6)
    ggsave(outfile, gg, width=297, height=210, units = "mm")
    
    outfile<-paste0(outdir,"/analysis-end-times-by-bin-qq.pdf")
    echo(paste0("Writing ", outfile, "\n"))
    gg<-ggplot(pp[pp$Stat=="Act.End.Time.Prob",], aes(x=Expected, y=Actual)) + 
      geom_abline(aes(colour='red', slope = 1, intercept=0)) +
      geom_point(aes(fill=Activity, colour=Activity), size=2, shape=21, alpha=1)  +
      guides(colour=FALSE, fill=guide_legend(title="")) +
      theme(legend.position="bottom") + 
      theme(plot.title = element_text(hjust = 0.5), strip.background = element_blank(), strip.text.x = element_blank()) +
      ggtitle(paste0('Activity End Time Probabilities in ',binSizeInMins,'-Min Bins')) +
      facet_wrap(~Bin, scales="free", ncol=6)
    ggsave(outfile, gg, width=297, height=210, units = "mm")
    
    outfile<-paste0(outdir,"/analysis-start-times-by-activity.pdf")
    echo(paste0("Writing ", outfile, "\n"))
    dd<-melt(pp[pp$Stat=="Act.Start.Time.Prob",], id.vars = c("Activity", "Stat", "Bin"))
    gg<-ggplot(dd, aes(x=Bin, y=value, fill=variable)) + 
      geom_bar(stat="identity", width=1, position = "dodge") + 
      scale_color_manual(values=c('#009B95', '#FF7100')) + 
      scale_fill_manual(values=c('#009B95', '#FF7100')) + 
      guides(colour=FALSE, fill=guide_legend(title="")) +
      facet_wrap(~Activity, scales="free", ncol=2) +
      theme(plot.title = element_text(hjust = 0.5)) +
      xlab("30-min time bins") + ylab("Proportion of population") +
      ggtitle(paste0('Activity Start Time by time of day'))
    ggsave(outfile, gg, width=210, height=297, units = "mm")
    
    outfile<-paste0(outdir,"/analysis-end-times-by-activity.pdf")
    echo(paste0("Writing ", outfile, "\n"))
    dd<-melt(pp[pp$Stat=="Act.End.Time.Prob",], id.vars = c("Activity", "Stat", "Bin"))
    gg<-ggplot(dd, aes(x=Bin, y=value, col=variable, fill=variable)) + 
      geom_bar(stat="identity", width=1, position = "dodge") + 
      scale_color_manual(values=c('#009B95', '#FF7100')) + 
      scale_fill_manual(values=c('#009B95', '#FF7100')) + 
      facet_wrap(~Activity, scales="free", ncol=2) +
      theme(plot.title = element_text(hjust = 0.5)) +
      xlab("30-min time bins") + ylab("Proportion of population") +
      ggtitle(paste0('Activity End Time by time of day'))
    ggsave(outfile, gg, width=210, height=297, units = "mm")
    
    outfile<-paste0(outdir,"/analysis-activity-times-by-bin.pdf")
    echo(paste0("Writing ", outfile, "\n"))
    dd<-melt(qq, id.vars = c("Stat", "Bin"))
    gg<-ggplot(dd, aes(x=Bin, y=value, col=variable, fill=variable)) + 
      geom_bar(stat="identity", width=0.8, position = "dodge") + 
      scale_color_manual(values=c('#009B95', '#FF7100')) + 
      scale_fill_manual(values=c('#009B95', '#FF7100')) + 
      guides(colour=FALSE, fill=guide_legend(title="")) +
      theme(legend.position="bottom") + 
      #theme(plot.title = element_text(hjust = 0.5), strip.background = element_blank(), strip.text.x = element_blank()) +
      xlab("30-min time bins") + ylab("Proportion of population") +
      ggtitle(paste0('Activity Start/End Time Probabilities in ',binSizeInMins,'-Min Bins')) +
      facet_wrap(~Stat, scales="free", ncol=1)
    ggsave(outfile, gg, width=210, height=297, units = "mm")
    
  }
  
  padWithHomeActivity <- function (inplansfile, outplansfile, numOfBins) {
    # Read in the plans
    gz1<-gzfile(inplansfile, 'rt')
    origplans<-read.csv(gz1, header=T, stringsAsFactors=F, strip.white=T)
    close(gz1)
    
    plans<-origplans
    
    # Add missing Home activity at the start of plans
    df<-origplans
    df<-aggregate(df,by=list(df$PlanId),FUN=head,1) # get the first row of each plan
    df<-df[df$Activity!="Home",] # get plans that do not start with a home activity
    # create the set of missing start-at-home activities 
    df$Activity<-"Home"
    df$EndBin<-df$StartBin
    df$StartBin<-1
    # now slot them in
    dd<-rbind(plans,df[,colnames(plans)]) # first append them to the end of original set of activities
    id<- c(plans$PlanId,(df$PlanId-0.5)) #give them half-rank indices ie where they should be slotted
    dy<-dd[order(id),] # now use order to pluck the set in the correct order

    plans<-dy
    
    # Add missing Home activity at the end of plans
    df<-plans
    df<-aggregate(df,by=list(df$PlanId),FUN=tail,1) # get the last row of each plan
    df<-df[df$Activity!="Home",] # get plans that do not start with a home activity
    # create the set of missing start-at-home activities 
    df$Activity<-"Home"
    df$StartBin<-df$EndBin
    df$EndBin<-numOfBins
    # now slot them in
    dd<-rbind(plans,df[,colnames(plans)]) # first append them to the end of original set of activities
    id<- c(plans$PlanId,(df$PlanId+0.5)) #give them half-rank indices ie where they should be slotted
    dy<-dd[order(id),] # now use order to pluck the set in the correct order
    
    plans<-dy
    
    # Finally stretch out any final Home activities that do not end in the last bin
    df<-plans
    df$rowId<-rownames(df)
    df<-aggregate(df,by=list(df$PlanId),FUN=tail,1) # get the last row of each plan
    filter<-df$EndBin!=numOfBins # get plans that do not end in the last bin  
    pids<-df[filter,]$rowId # get ids of plans that do not end in the last bin
    dy<-plans
    dy[pids,]$EndBin<-numOfBins

    rownames(dy)<-1:nrow(dy) # clean up the row names 
    plans<-dy
    write.table(plans, file=outplansfile, append=FALSE, row.names=FALSE, sep = ',')
  }
  
  options(scipen=999) # disable scientific notation for more readible filenames with small sample sizes
  
  # create the output directory if needed
  dir.create(outdir, showWarnings = FALSE, recursive=TRUE)
  
  # Read in the time bins
  echo(paste0("Loading extracted VISTA 2012-18 activities by time bins from ", csv, "\n"))
  gz1 <- gzfile(csv,'rt')
  bins<-read.csv(gz1,header = T,sep=',',stringsAsFactors = F,strip.white = T)
  bins[is.na(bins)]<-0 # convert NAs to 0s
  close(gz1)
  
  # Read in the end bin distributions per start bin
  echo(paste0("Loading extracted VISTA 2012-18 activities end bin distributions per start bin from ", endcsv, "\n"))
  gz1 <- gzfile(endcsv,'rt')
  endbins<-read.csv(gz1,header = T,sep=',',stringsAsFactors = F,strip.white = T)
  endbins[is.na(endbins)]<-0 # convert NAs to 0s
  close(gz1)
  
  # bins: data frame with the following columns:
  # Activity.Group, Activity.Stat, X1..XN where N is the enumber of time bins in the day; and
  #
  # unique(bins$Activity.Group)
  # [1] "Home Morning"           "Work"                   "Home Night"             "Pickup/Dropoff/Deliver"
  # [5] "Shop"                   "Home Daytime"           "Study"                  "Personal"              
  # [9] "Other"                  "Social/Recreational"    "With Someone"           "Mode Change"           
  #
  # unique(bins$Activity.Stat)
  # "Act.Start.Time.Prob"     "Act.End.Time.Prob"       "Act.Duration.Mins.Mean"  "Act.Duration.Mins.Sigma"
  
  # make a copy of the bins to track progress
  newbins<-data.frame(bins)
  newbins[,binCols]<-0
  binIndexOffset<-head(binCols,1)-1
  
  # generate the plans
  outfile<-paste0(outdir, '/plan.csv')
  echo(paste0("Generating ",N," VISTA-like daily travel plans into ", outfile, "\n"))
  plans<-data.frame(PlanId=integer(), Activity=factor(levels=getActivityGroups(bins)), StartBin=integer(), EndBin=integer())
  write.table(plans, file=outfile, append=FALSE, row.names=FALSE, sep = ',')
  for(i in 1:N) {
    # print progress
    printProgress(i,'.')
    # create a new plan and add it to the list
    plan<-createNewPlan(bins, newbins, endbins, binCols)
    plan<-cbind(PlanId=i, plan)
    # record progress
    newbins<-recordProgress(plan, newbins, binCols)
    # add it to our list
    plans<-rbind(plans, plan)
    # write it out at regular intervals
    if (i%%writeInterval==0 || i==N) {
      write.table(plans, file=outfile, append=TRUE, row.names=FALSE, col.names=FALSE, sep = ',')
      plans<-plans[FALSE,] # remove all rows
    }
  }
  # write out the analyses PDFs
  echo(paste0("Generating analysis graphs\n"))
  analysePlans(bins, newbins, outdir)
  # make all plans start/finish at home
  inplansfile<-outfile
  outplansfile<-outfile
  numOfBins<-length(binCols)
  echo(paste0("Padding generated plans with Home activity to make them MATSim-ready (can take a while)\n"))
  padWithHomeActivity(inplansfile, outplansfile, numOfBins)
  echo(paste0("Wrote ",outplansfile,"\n"))
}

# example usage
runexample<- function(num) {
  N<-num # generate 10k VISTA 2012-18 like daily plans
  csv<-paste0('./output/1.setup/vista_2012_18_extracted_activities_weekday_time_bins.csv.gz')
  endcsv<-paste0('./output/1.setup/vista_2012_18_extracted_activities_weekday_end_dist_for_start_bins.csv.gz')
  binCols<-3:50 # specifies that columns 3-50 correspond to 48 time bins, i.e., 30-mins each
  outdir<-'./output/3.plan'
  writeInterval <- 1000 # write to file every 1000 plans
  generatePlans(N, csv, endcsv, binCols, outdir, writeInterval)
}  
