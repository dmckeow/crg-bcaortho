
extract_ogs_uniprot <- function(proteins = NULL) {
    
    ogs <- lapply(proteins, function(x) {
        
        url <- paste0("https://www.ebi.ac.uk/proteins/api/proteins/", x)
        request <- httr::GET(url)
        annot <- httr::content(request, type = "application/json", 
                               as = "parsed", encoding = "UTF-8")
        dbref <- lapply(annot$dbReferences, as.data.frame)
        names(dbref) <- vapply(dbref, function(x) return(x$type), character(1))
        
        orthodb <- NA
        eggnog <- NA
        inparanoid <- NA
        phylomedb <- NA
        hogenom <- NA
        if("eggNOG" %in% names(dbref)) {
            eggnog <- dbref$eggNOG$id
        }
        if("OrthoDB" %in% names(dbref)) {
            orthodb <- dbref$OrthoDB$id
        }
        if("InParanoid" %in% names(dbref)) {
            inparanoid <- dbref$InParanoid$id
        }
        if("PhylomeDB" %in% names(dbref)) {
            phylomedb <- dbref$PhylomeDB$id
        }
        if("HOGENOM" %in% names(dbref)) {
            hogenom <- dbref$HOGENOM$id
        }
        if(!"Araport" %in% names(dbref)) {
            df <- NULL
        } else {
            df <- data.frame(
                Gene = dbref$Araport$id,
                OrthoDB = orthodb,
                eggNOG = eggnog,
                OrthoDB = orthodb,
                InParanoid = inparanoid,
                PhylomeDB = phylomedb,
                HOGENOM = hogenom
            )
        }
        return(df)
    })
    og_df <- Reduce(rbind, ogs)
    return(og_df)
}


compare <- function(data, form, ref = NULL) {
    # Wilcoxon test - greater and less alternatives
    wilcoxtest_greater <- tibble::as_tibble(data) %>%
        rstatix::wilcox_test(
            formula(form), p.adjust.method = "BH", ref.group = ref,
            alternative = "greater"
        )
    pg <- ifelse("p.adj" %in% names(wilcoxtest_greater), "p.adj", "p")
    wilcoxtest_greater <- wilcoxtest_greater %>% dplyr::select(
            group1, group2, n1, n2, padj_greater = all_of(pg)
        )
    
    wilcoxtest_less <- tibble::as_tibble(data) %>%
        rstatix::wilcox_test(
            formula(form), p.adjust.method = "BH", ref.group = ref,
            alternative = "less"
        )
    pl <- ifelse("p.adj" %in% names(wilcoxtest_less), "p.adj", "p")
    wilcoxtest_less <- wilcoxtest_less %>% dplyr::select(
        group1, group2, n1, n2, padj_less = all_of(pl)
    )
    
    wilcox_summary <- dplyr::inner_join(wilcoxtest_greater, wilcoxtest_less) %>%
        dplyr::mutate(padj_interpretation = dplyr::case_when(
            padj_less < 0.05 ~ "less",
            padj_greater < 0.05 ~ "greater",
            TRUE ~ "ns"
        ))
    
    # Effect sizes for Wilcoxon test - greater and less alternatives
    
    effsize <- tibble::as_tibble(data) %>%
        rstatix::wilcox_effsize(
            formula(form), ref.group = ref,
        ) %>%
        dplyr::select(
            group1, group2, effsize, magnitude
        )
    
    
    result <- as.data.frame(inner_join(wilcox_summary, effsize))
        
    return(result)
}


filter_comparison <- function(compare_output) {
    
    filtered_df <- compare_output |>
        dplyr::filter(padj_interpretation != "ns") |>
        mutate(padj = case_when(
            padj_interpretation == "greater" ~ padj_greater,
            padj_interpretation == "less" ~ padj_less
        )) |>
        dplyr::select(group1, group2, n1, n2, padj, effsize, magnitude)
    
    return(filtered_df)
}


overclustering_correction <- function(
        homogeneity_df, orthogroup_df, update_score = TRUE
) {
    
    # Calculate % of domains present in 2+ OGs
    dispersal <- split(orthogroup_df, orthogroup_df$Annotation)
    dispersal <- unlist(lapply(dispersal, function(x) {
        return(length(unique(x$Orthogroup)))
    }))
    
    dispersal_freq <- (sum(dispersal > 1) / length(dispersal))
    
    if(update_score) {
        homogeneity_df$Score <- homogeneity_df$Score / dispersal_freq
    } else {
        homogeneity_df$Dispersal <- dispersal_freq
        homogeneity_df$Score_c <- homogeneity_df$Score - dispersal_freq
    }
    
    return(homogeneity_df)
}


calculate_H_with_terms <- function(
        orthogroup_df, max_size = 200, get_mean = TRUE,
        correct_overclustering = TRUE, update_score = TRUE
) {
    
    by_og <- split(orthogroup_df, orthogroup_df$Orthogroup)
    
    # Calculate OG sizes
    og_sizes <- vapply(by_og, function(x) {
        return(length(unique(x$Gene)))
    }, numeric(1))
    perc_excluded <- (sum(og_sizes >= max_size) / length(og_sizes)) * 100
    
    # Calculate homogeneity scores
    sdice <- Reduce(rbind, lapply(by_og, function(x) {
        
        ngenes <- length(unique(x$Gene))
        og <- unique(x$Orthogroup)
        
        x <- x[!is.na(x$Annotation), ]
        annot_genes <- unique(x$Gene)
        
        scores_df <- NULL
        if(length(annot_genes) > 1 & ngenes <= max_size) {
            
            # Calculate Sorensen-Dice indices for all pairwise combinations
            combinations <- utils::combn(annot_genes, 2, simplify = FALSE)
            scores <- lapply(combinations, function(y) {
                d1 <- x$Annotation[x$Gene == y[1]]
                d2 <- x$Annotation[x$Gene == y[2]]
                
                numerator <- 2 * length(intersect(d1, d2))
                denominator <- length(d1) + length(d2)
                s <- round(numerator / denominator, 2)
                return(s)
            })
            scores <- unlist(scores) - perc_excluded * 0.1
            if(get_mean) { scores <- mean(scores) }
            
            scores_df <- data.frame(
                Orthogroup = og,
                Score = scores
            )
        }
        return(scores_df)
    }))
    
    # Account for overclustering
    if(correct_overclustering) {
        sdice <- overclustering_correction(sdice, orthogroup_df, update_score)
    }
    
    
    return(sdice)
}
